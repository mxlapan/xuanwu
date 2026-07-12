// Package reality generates REALITY x25519 keypairs and short IDs, compatible
// with `xray x25519`. Private/public keys are base64 RawURL encoded.
package reality

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"

	"golang.org/x/crypto/curve25519"
)

// GenerateKeypair returns (privateKey, publicKey) base64 RawURL encoded, the
// same encoding Xray expects in realitySettings.privateKey and clients use as
// the public key (pbk).
func GenerateKeypair() (string, string, error) {
	var priv [32]byte
	if _, err := rand.Read(priv[:]); err != nil {
		return "", "", err
	}
	// clamp per RFC 7748 (same as xray x25519)
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64

	pub, err := curve25519.X25519(priv[:], curve25519.Basepoint)
	if err != nil {
		return "", "", err
	}
	enc := base64.RawURLEncoding
	return enc.EncodeToString(priv[:]), enc.EncodeToString(pub), nil
}

// GenerateShortID returns a random 8-byte (16 hex chars) REALITY shortId.
func GenerateShortID() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
