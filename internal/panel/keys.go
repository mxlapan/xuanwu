package panel

import (
	"net/http"

	"xuanwu/internal/nodekey"
)

// handleRealityKeys generates a fresh node x25519 keypair + shortId so the admin
// can fill the node form without shelling into a server.
func (a *App) handleRealityKeys(w http.ResponseWriter, r *http.Request) {
	priv, pub, err := nodekey.GenerateKeypair()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	shortID, err := nodekey.GenerateShortID()
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
