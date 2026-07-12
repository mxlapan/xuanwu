package panel

import (
	"encoding/json"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
)

// liveSettings holds panel configuration that is editable at runtime from the
// settings panel. Each value is seeded from an environment variable on boot and
// then overridden by anything saved to the DB `settings` table, so operators
// keep only a minimal bootstrap .env and configure the rest in the panel.
type liveSettings struct {
	mu            sync.Mutex
	publicURL     string // external base URL used in links
	cookieSecure  string // "auto" | "on" | "off"
	backupKeep    int    // daily snapshots to retain
	clashTemplate string // Clash base config; {{PROXIES}}/{{PROXY_NAMES}} are injected
}

// loadSettings seeds from env/defaults, then applies DB overrides.
func (a *App) loadSettings(seedPublicURL string, seedBackupKeep int) {
	a.settings.mu.Lock()
	defer a.settings.mu.Unlock()

	a.settings.publicURL = seedPublicURL
	a.settings.backupKeep = seedBackupKeep
	// cookie mode seeds from PANEL_COOKIE_SECURE if the operator set it, else auto.
	switch strings.ToLower(strings.TrimSpace(os.Getenv("PANEL_COOKIE_SECURE"))) {
	case "1", "true", "yes", "on":
		a.settings.cookieSecure = "on"
	case "0", "false", "no", "off":
		a.settings.cookieSecure = "off"
	default:
		a.settings.cookieSecure = "auto"
	}

	if v, ok, _ := a.store.GetSetting("public_url"); ok && v != "" {
		a.settings.publicURL = v
	}
	if v, ok, _ := a.store.GetSetting("cookie_secure"); ok && v != "" {
		a.settings.cookieSecure = v
	}
	if v, ok, _ := a.store.GetSetting("backup_keep"); ok {
		if n, err := strconv.Atoi(v); err == nil {
			a.settings.backupKeep = n
		}
	}
	if v, ok, _ := a.store.GetSetting("clash_template"); ok {
		a.settings.clashTemplate = v
	}
}

func (a *App) clashTemplate() string {
	a.settings.mu.Lock()
	defer a.settings.mu.Unlock()
	return a.settings.clashTemplate
}

func (a *App) publicURL() string {
	a.settings.mu.Lock()
	defer a.settings.mu.Unlock()
	return a.settings.publicURL
}

// cookieSecure resolves the tri-state mode into a bool for a Set-Cookie call.
func (a *App) cookieSecure() bool {
	a.settings.mu.Lock()
	defer a.settings.mu.Unlock()
	switch a.settings.cookieSecure {
	case "on":
		return true
	case "off":
		return false
	default:
		return strings.HasPrefix(strings.ToLower(a.settings.publicURL), "https://")
	}
}

func (a *App) backupKeep() int {
	a.settings.mu.Lock()
	defer a.settings.mu.Unlock()
	return a.settings.backupKeep
}

func (a *App) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	a.settings.mu.Lock()
	out := map[string]any{
		"public_url":     a.settings.publicURL,
		"cookie_secure":  a.settings.cookieSecure,
		"backup_keep":    a.settings.backupKeep,
		"clash_template": a.settings.clashTemplate,
	}
	a.settings.mu.Unlock()
	writeJSON(w, 200, out)
}

func (a *App) handlePutSettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PublicURL     *string `json:"public_url"`
		CookieSecure  *string `json:"cookie_secure"`
		BackupKeep    *int    `json:"backup_keep"`
		ClashTemplate *string `json:"clash_template"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, 400, "bad body")
		return
	}

	// validate before mutating anything
	var pub, cookie string
	if body.PublicURL != nil {
		pub = strings.TrimRight(strings.TrimSpace(*body.PublicURL), "/")
		if pub != "" && !strings.HasPrefix(pub, "http://") && !strings.HasPrefix(pub, "https://") {
			writeErr(w, 400, "public_url must start with http:// or https://")
			return
		}
	}
	if body.CookieSecure != nil {
		cookie = strings.ToLower(strings.TrimSpace(*body.CookieSecure))
		if cookie != "auto" && cookie != "on" && cookie != "off" {
			writeErr(w, 400, "cookie_secure must be auto, on or off")
			return
		}
	}
	keep := -1
	if body.BackupKeep != nil {
		keep = *body.BackupKeep
		if keep < 0 {
			keep = 0
		}
		if keep > 365 {
			keep = 365
		}
	}

	a.settings.mu.Lock()
	if body.PublicURL != nil {
		a.settings.publicURL = pub
		_ = a.store.SetSetting("public_url", pub)
	}
	if body.CookieSecure != nil {
		a.settings.cookieSecure = cookie
		_ = a.store.SetSetting("cookie_secure", cookie)
	}
	if body.BackupKeep != nil {
		a.settings.backupKeep = keep
		_ = a.store.SetSetting("backup_keep", strconv.Itoa(keep))
	}
	if body.ClashTemplate != nil {
		tpl := strings.ReplaceAll(*body.ClashTemplate, "\r\n", "\n")
		a.settings.clashTemplate = tpl
		_ = a.store.SetSetting("clash_template", tpl)
	}
	a.settings.mu.Unlock()

	a.audit(r, "settings.update", "")
	a.handleGetSettings(w, r)
}
