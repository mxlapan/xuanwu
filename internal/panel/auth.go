package panel

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"golang.org/x/crypto/bcrypt"
)

// signSession builds a stateless "role|subject|epoch|expiry|sig" token signed
// with the panel secret. The role is part of the signed payload so an admin
// session and a self-service portal session are cryptographically distinct: a
// portal token can never be replayed as an admin token. The epoch is compared
// against the account's current epoch at verify time, so bumping it (password
// change, "sign out everywhere") revokes every outstanding session for that
// account without any server-side session store.
func signSession(secret, role, subject string, epoch int64, ttl time.Duration) string {
	exp := time.Now().Add(ttl).Unix()
	payload := fmt.Sprintf("%s|%s|%d|%d", role, subject, epoch, exp)
	sig := hmacHex(secret, payload)
	return base64.RawURLEncoding.EncodeToString([]byte(payload + "|" + sig))
}

// verifySession returns the token's role, subject and epoch if the signature is
// valid and it has not expired. Callers must still check the epoch against the
// account's current epoch.
func verifySession(secret, token string) (role, subject string, epoch int64, ok bool) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return "", "", 0, false
	}
	parts := strings.Split(string(raw), "|")
	if len(parts) != 5 {
		return "", "", 0, false
	}
	role, subject, epochStr, expStr, sig := parts[0], parts[1], parts[2], parts[3], parts[4]
	if !hmac.Equal([]byte(sig), []byte(hmacHex(secret, role+"|"+subject+"|"+epochStr+"|"+expStr))) {
		return "", "", 0, false
	}
	epoch, err = strconv.ParseInt(epochStr, 10, 64)
	if err != nil {
		return "", "", 0, false
	}
	exp, err := strconv.ParseInt(expStr, 10, 64)
	if err != nil || time.Now().Unix() >= exp {
		return "", "", 0, false
	}
	return role, subject, epoch, true
}

func hmacHex(secret, msg string) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(msg))
	return hex.EncodeToString(m.Sum(nil))
}

// errWeakPassword describes the required password strength.
var errWeakPassword = errors.New("password must be at least 8 characters and include uppercase, lowercase, a digit, and a special character")

// validatePasswordStrength enforces the panel-wide password policy.
func validatePasswordStrength(pw string) error {
	if len(pw) < 8 {
		return errWeakPassword
	}
	var hasUpper, hasLower, hasDigit, hasSpecial bool
	for _, r := range pw {
		switch {
		case unicode.IsUpper(r):
			hasUpper = true
		case unicode.IsLower(r):
			hasLower = true
		case unicode.IsDigit(r):
			hasDigit = true
		case unicode.IsPunct(r) || unicode.IsSymbol(r):
			hasSpecial = true
		}
	}
	if hasUpper && hasLower && hasDigit && hasSpecial {
		return nil
	}
	return errWeakPassword
}

func hashPassword(pw string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	return string(b), err
}

func checkPassword(hash, pw string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(pw)) == nil
}

// requireAuth wraps admin-only HTTP handlers, checking the session cookie carries
// a valid, unexpired admin-role token.
func (a *App) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := r.Cookie("xuanwu_session")
		if err != nil {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		role, name, epoch, ok := verifySession(a.cfg.JWTSecret, c.Value)
		if !ok || role != roleAdmin {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		adm, err := a.store.GetAdmin(name)
		if err != nil || adm.SessionEpoch != epoch {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// session roles embedded in signed tokens.
const (
	roleAdmin = "admin"
	roleUser  = "user"
)

// randBytes fills b with cryptographic randomness or panics. A failing CSPRNG
// is unrecoverable, and silently emitting predictable tokens/keys would be worse
// than crashing, so we treat it as fatal.
func randBytes(b []byte) {
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
}

// randToken returns a URL-safe random token of n bytes of entropy.
func randToken(n int) string {
	b := make([]byte, n)
	randBytes(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// newUUID returns a random RFC-4122 v4 UUID string.
func newUUID() string {
	b := make([]byte, 16)
	randBytes(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// clientIP extracts the remote host without the port. It intentionally does not
// trust X-Forwarded-For (spoofable); operators behind a proxy should rate-limit
// at the proxy too.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// limiter is a tiny fixed-window failure counter used to throttle login attempts
// per source IP and per targeted username.
type limiter struct {
	mu      sync.Mutex
	entries map[string]*limEntry
	max     int
	window  time.Duration
}

type limEntry struct {
	count int
	reset time.Time
}

func newLimiter(max int, window time.Duration) *limiter {
	return &limiter{entries: map[string]*limEntry{}, max: max, window: window}
}

// blocked reports whether key has exhausted its allowance in the current window.
func (l *limiter) blocked(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.entries[key]
	if e == nil {
		return false
	}
	if time.Now().After(e.reset) {
		delete(l.entries, key)
		return false
	}
	return e.count >= l.max
}

// fail records one failed attempt for key.
func (l *limiter) fail(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	e := l.entries[key]
	if e == nil || now.After(e.reset) {
		e = &limEntry{reset: now.Add(l.window)}
		l.entries[key] = e
	}
	e.count++
	// opportunistic cleanup so the map can't grow without bound
	if len(l.entries) > 4096 {
		for k, v := range l.entries {
			if now.After(v.reset) {
				delete(l.entries, k)
			}
		}
	}
}

// reset clears the counter for key (e.g. after a successful login).
func (l *limiter) reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.entries, key)
}
