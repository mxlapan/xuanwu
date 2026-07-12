package panel

import (
	"encoding/json"
	"net/http"

	"rsc.io/qr"
)

// currentAdmin resolves the admin behind an authenticated request.
func (a *App) currentAdmin(r *http.Request) (*Admin, bool) {
	c, err := r.Cookie("xuanwu_session")
	if err != nil {
		return nil, false
	}
	role, name, epoch, ok := verifySession(a.cfg.JWTSecret, c.Value)
	if !ok || role != roleAdmin {
		return nil, false
	}
	adm, err := a.store.GetAdmin(name)
	if err != nil || adm.SessionEpoch != epoch {
		return nil, false
	}
	return adm, true
}

func (a *App) handle2FAStatus(w http.ResponseWriter, r *http.Request) {
	adm, ok := a.currentAdmin(r)
	if !ok {
		writeErr(w, 401, "unauthorized")
		return
	}
	writeJSON(w, 200, map[string]bool{
		"enabled": adm.TOTPEnabled,
		"pending": !adm.TOTPEnabled && adm.TOTPSecret != "",
	})
}

// handle2FASetup provisions a fresh (not-yet-enabled) secret and returns the
// enrolment URL. Enabling requires a follow-up verify with a valid code.
func (a *App) handle2FASetup(w http.ResponseWriter, r *http.Request) {
	adm, ok := a.currentAdmin(r)
	if !ok {
		writeErr(w, 401, "unauthorized")
		return
	}
	if adm.TOTPEnabled {
		writeErr(w, 400, "2fa already enabled; disable it first")
		return
	}
	secret := newTOTPSecret()
	if err := a.store.SetAdminTOTP(adm.Username, secret, false); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]string{
		"secret":      secret,
		"otpauth_url": otpauthURL("Xuanwu", adm.Username, secret),
	})
}

func (a *App) handle2FAVerify(w http.ResponseWriter, r *http.Request) {
	adm, ok := a.currentAdmin(r)
	if !ok {
		writeErr(w, 401, "unauthorized")
		return
	}
	var body struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, 400, "bad body")
		return
	}
	if adm.TOTPSecret == "" || !totpVerify(adm.TOTPSecret, body.Code) {
		writeErr(w, 400, "invalid code")
		return
	}
	if err := a.store.SetAdminTOTP(adm.Username, adm.TOTPSecret, true); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	a.audit(r, "2fa.enable", adm.Username)
	writeJSON(w, 200, map[string]bool{"enabled": true})
}

func (a *App) handle2FADisable(w http.ResponseWriter, r *http.Request) {
	adm, ok := a.currentAdmin(r)
	if !ok {
		writeErr(w, 401, "unauthorized")
		return
	}
	// Require a current code to disable, so a hijacked session can't turn it off.
	var body struct {
		Code string `json:"code"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if adm.TOTPEnabled && !totpVerify(adm.TOTPSecret, body.Code) {
		writeErr(w, 400, "invalid code")
		return
	}
	if err := a.store.SetAdminTOTP(adm.Username, "", false); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	a.audit(r, "2fa.disable", adm.Username)
	writeJSON(w, 200, map[string]bool{"enabled": false})
}

// handle2FAQR renders the enrolment secret as a QR (otpauth URL) for the pending
// or active secret of the current admin.
func (a *App) handle2FAQR(w http.ResponseWriter, r *http.Request) {
	adm, ok := a.currentAdmin(r)
	if !ok || adm.TOTPSecret == "" {
		http.Error(w, "no secret", http.StatusNotFound)
		return
	}
	code, err := qr.Encode(otpauthURL("Xuanwu", adm.Username, adm.TOTPSecret), qr.M)
	if err != nil {
		http.Error(w, "qr", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(code.PNG())
}
