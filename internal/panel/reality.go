package panel

import (
	"net/http"

	"xuanwu/internal/reality"
)

// handleRealityKeys generates a fresh REALITY x25519 keypair + shortId so the
// admin can fill the node form without shelling into a server. Matches the
// output of `xray x25519`.
func (a *App) handleRealityKeys(w http.ResponseWriter, r *http.Request) {
	priv, pub, err := reality.GenerateKeypair()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	shortID, err := reality.GenerateShortID()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]string{
		"private_key": priv,
		"public_key":  pub,
		"short_id":    shortID,
	})
}
