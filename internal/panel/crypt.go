package panel

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"io"
	"strings"

	"golang.org/x/crypto/hkdf"
)

// encPrefix marks a value produced by (*crypter).encrypt. Values without it are
// treated as legacy plaintext, so a database written by an earlier version stays
// readable and is re-encrypted in place on the next boot (see encryptExisting).
const encPrefix = "enc:v1:"

// crypter encrypts secret database columns at rest with AES-256-GCM. The key is
// derived from the panel's session secret (PANEL_JWT_SECRET) via HKDF, so no
// extra key material is needed — but it makes a stable secret mandatory: a
// changed or ephemeral secret can no longer decrypt existing data.
type crypter struct {
	aead cipher.AEAD
}

// newCrypter derives an AES-256-GCM AEAD from secret. A blank secret returns nil,
// which the encrypt/decrypt helpers treat as "encryption disabled" (plaintext) —
// used by tests that open a bare store.
func newCrypter(secret string) *crypter {
	if secret == "" {
		return nil
	}
	key := make([]byte, 32)
	kdf := hkdf.New(sha256.New, []byte(secret), nil, []byte("xuanwu-db-encryption-v1"))
	if _, err := io.ReadFull(kdf, key); err != nil {
		panic("derive db encryption key: " + err.Error())
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		panic("db cipher: " + err.Error())
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		panic("db gcm: " + err.Error())
	}
	return &crypter{aead: aead}
}

// isEncrypted reports whether v carries the at-rest ciphertext marker.
func isEncrypted(v string) bool { return strings.HasPrefix(v, encPrefix) }

// encrypt returns the at-rest ciphertext for s. It is a no-op for the empty
// string (so an unset secret stays "" and existing == "" checks keep working),
// for a nil crypter (encryption disabled), and for already-encrypted input (so
// re-encryption is idempotent).
func (c *crypter) encrypt(s string) string {
	if c == nil || s == "" || isEncrypted(s) {
		return s
	}
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	ct := c.aead.Seal(nonce, nonce, []byte(s), nil)
	return encPrefix + base64.RawStdEncoding.EncodeToString(ct)
}

// decrypt reverses encrypt. Legacy plaintext (no marker) passes through so an
// un-migrated value is still usable. A marked value with no key, or one that
// fails to decrypt (wrong/rotated secret, tampering), returns "" rather than
// leaking raw ciphertext bytes.
func (c *crypter) decrypt(s string) string {
	if !isEncrypted(s) {
		return s
	}
	if c == nil {
		return ""
	}
	raw, err := base64.RawStdEncoding.DecodeString(strings.TrimPrefix(s, encPrefix))
	if err != nil || len(raw) < c.aead.NonceSize() {
		return ""
	}
	nonce, ct := raw[:c.aead.NonceSize()], raw[c.aead.NonceSize():]
	pt, err := c.aead.Open(nil, nonce, ct, nil)
	if err != nil {
		return ""
	}
	return string(pt)
}
