package panel

import (
	"encoding/json"
	"net/http"
	"strings"
)

// audit records an admin action, attributing it to the caller.
func (a *App) audit(r *http.Request, action, detail string) {
	actor := "?"
	if adm, ok := a.currentAdmin(r); ok {
		actor = adm.Username
	}
	_ = a.store.AddAudit(actor, action, detail)
}

func (a *App) handleListAdmins(w http.ResponseWriter, r *http.Request) {
	admins, err := a.store.ListAdmins()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, admins)
}

func (a *App) handleCreateAdmin(w http.ResponseWriter, r *http.Request) {
	var body struct{ Username, Password string }
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, 400, "bad body")
		return
	}
	body.Username = strings.TrimSpace(body.Username)
	if err := validateUsername(body.Username); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if err := validatePasswordStrength(body.Password); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if _, err := a.store.GetAdmin(body.Username); err == nil {
		writeErr(w, 409, "admin already exists")
		return
	}
	hash, err := hashPassword(body.Password)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if err := a.store.CreateAdmin(body.Username, hash); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	a.audit(r, "admin.create", body.Username)
	writeJSON(w, 201, map[string]string{"username": body.Username})
}

func (a *App) handleDeleteAdmin(w http.ResponseWriter, r *http.Request) {
	username := r.PathValue("username")
	n, err := a.store.CountAdmins()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if n <= 1 {
		writeErr(w, 400, "cannot delete the last admin")
		return
	}
	if err := a.store.DeleteAdmin(username); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	// Revoke the removed admin's sessions immediately.
	_ = a.store.BumpAdminSessionEpoch(username)
	a.audit(r, "admin.delete", username)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (a *App) handleChangeAdminPassword(w http.ResponseWriter, r *http.Request) {
	username := r.PathValue("username")
	if _, err := a.store.GetAdmin(username); err != nil {
		writeErr(w, 404, "not found")
		return
	}
	var body struct{ Password string }
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, 400, "bad body")
		return
	}
	if err := validatePasswordStrength(body.Password); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	hash, err := hashPassword(body.Password)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if err := a.store.SetAdminPassword(username, hash); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	a.audit(r, "admin.password", username)
	writeJSON(w, 200, map[string]bool{"ok": true})
}

func (a *App) handleListAudit(w http.ResponseWriter, r *http.Request) {
	entries, err := a.store.ListAudit(100)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, entries)
}
