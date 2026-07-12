package panel

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"rsc.io/qr"
)

// The self-service portal lets an end user sign in with their username and a
// portal password (set by the admin) to view their own quota, expiry, assigned
// nodes and subscription links. It shares nothing with the admin surface: a
// distinct cookie, a distinct session role, and handlers that only ever read the
// authenticated user's own row.

const portalCookie = "xuanwu_portal"

// portalUser resolves the authenticated portal user from the request cookie, or
// returns false. It requires a valid, unexpired token with the "user" role.
func (a *App) portalUser(r *http.Request) (*User, bool) {
	c, err := r.Cookie(portalCookie)
	if err != nil {
		return nil, false
	}
	role, subject, epoch, ok := verifySession(a.cfg.JWTSecret, c.Value)
	if !ok || role != roleUser {
		return nil, false
	}
	id, err := strconv.ParseInt(subject, 10, 64)
	if err != nil {
		return nil, false
	}
	u, err := a.store.GetUser(id)
	if err != nil || u.SessionEpoch != epoch {
		return nil, false
	}
	return u, true
}

// handlePortalPage serves the embedded portal SPA.
func (a *App) handlePortalPage(w http.ResponseWriter, r *http.Request) {
	b, err := webFS.ReadFile("web/portal.html")
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(b)
}

func (a *App) handlePortalLogin(w http.ResponseWriter, r *http.Request) {
	var body struct{ Username, Password string }
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad body")
		return
	}
	ipKey := "pip:" + clientIP(r)
	userKey := "puser:" + body.Username
	if a.loginLimiter.blocked(ipKey) || a.loginLimiter.blocked(userKey) {
		writeErr(w, http.StatusTooManyRequests, "too many attempts; try again later")
		return
	}
	u, err := a.store.GetUserByName(body.Username)
	// Constant work whether or not the account exists / has a password: always run
	// a bcrypt comparison so timing doesn't reveal which usernames are valid.
	hash := "$2a$10$invalidinvalidinvalidinvalidinvalidinvalidinvalidinvalidin"
	if err == nil && u.PortalPasswordHash != "" {
		hash = u.PortalPasswordHash
	}
	if !checkPassword(hash, body.Password) || err != nil || u.PortalPasswordHash == "" {
		a.loginLimiter.fail(ipKey)
		a.loginLimiter.fail(userKey)
		writeErr(w, http.StatusUnauthorized, "invalid credentials")
		return
	}
	a.loginLimiter.reset(ipKey)
	a.loginLimiter.reset(userKey)
	tok := signSession(a.cfg.JWTSecret, roleUser, strconv.FormatInt(u.ID, 10), u.SessionEpoch, 24*time.Hour)
	http.SetCookie(w, &http.Cookie{
		Name: portalCookie, Value: tok, Path: "/", HttpOnly: true,
		Secure: a.cookieSecure(), SameSite: http.SameSiteLaxMode, MaxAge: 86400,
	})
	writeJSON(w, http.StatusOK, map[string]string{"username": u.Username})
}

func (a *App) handlePortalLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{
		Name: portalCookie, Value: "", Path: "/", HttpOnly: true,
		Secure: a.cookieSecure(), SameSite: http.SameSiteLaxMode, MaxAge: -1,
	})
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handlePortalMe returns only the authenticated user's own account view.
func (a *App) handlePortalMe(w http.ResponseWriter, r *http.Request) {
	u, ok := a.portalUser(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	now := time.Now().Unix()
	nodes := make([]map[string]any, 0)
	for _, n := range a.userNodesList(u) {
		nodes = append(nodes, map[string]any{
			"name":  n.Name,
			"links": nodeLinks(u, n),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"username":    u.Username,
		"enabled":     u.Enabled,
		"active":      u.active(now),
		"data_used":   u.DataUsed,
		"data_limit":  u.DataLimit,
		"expire_at":   u.ExpireAt,
		"must_change": u.MustChangePW,
		"nodes":       nodes,
		"sub_url":     fmt.Sprintf("%s/sub/%s", a.publicURL(), u.SubToken),
		"clash_url":   fmt.Sprintf("%s/sub/%s/clash", a.publicURL(), u.SubToken),
		"singbox_url": fmt.Sprintf("%s/sub/%s/singbox", a.publicURL(), u.SubToken),
	})
}

// handlePortalChangePassword lets a signed-in portal user set a new password.
// It clears the must-change flag, rotates the session epoch, and re-issues this
// session's cookie so the current tab stays logged in while other sessions drop.
func (a *App) handlePortalChangePassword(w http.ResponseWriter, r *http.Request) {
	u, ok := a.portalUser(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var body struct {
		NewPassword string `json:"new_password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad body")
		return
	}
	if err := validatePasswordStrength(strings.TrimSpace(body.NewPassword)); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	hash, err := hashPassword(body.NewPassword)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if err := a.store.ChangeUserPortalPassword(u.ID, hash); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	// Re-issue this session with the bumped epoch so it remains valid.
	fresh, err := a.store.GetUser(u.ID)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	tok := signSession(a.cfg.JWTSecret, roleUser, strconv.FormatInt(u.ID, 10), fresh.SessionEpoch, 24*time.Hour)
	http.SetCookie(w, &http.Cookie{
		Name: portalCookie, Value: tok, Path: "/", HttpOnly: true,
		Secure: a.cookieSecure(), SameSite: http.SameSiteLaxMode, MaxAge: 86400,
	})
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handlePortalQR renders a PNG QR code of the authenticated user's own
// subscription URL (t=sub, default) or Clash URL (t=clash). It never encodes
// caller-supplied data, only the user's own tokens.
func (a *App) handlePortalQR(w http.ResponseWriter, r *http.Request) {
	u, ok := a.portalUser(r)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	target := fmt.Sprintf("%s/sub/%s", a.publicURL(), u.SubToken)
	if r.URL.Query().Get("t") == "clash" {
		target += "/clash"
	}
	code, err := qr.Encode(target, qr.M)
	if err != nil {
		http.Error(w, "qr", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(code.PNG())
}
