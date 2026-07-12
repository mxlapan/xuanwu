// Package panel implements the central control panel: admin API, embedded SPA,
// node WebSocket hub, subscriptions and traffic enforcement.
package panel

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"xuanwu/internal/wire"
)

//go:embed web
var webFS embed.FS

type Config struct {
	Listen        string
	DBPath        string
	JWTSecret     string
	AdminUser     string
	AdminPass     string
	PublicURL     string
	CookieSecure  bool    // mark the session cookie Secure (HTTPS-only)
	AllowWeakPass bool    // escape hatch for the default-password guard
	BackupDir     string  // directory for scheduled DB snapshots ("" disables)
	BackupKeep    int     // number of daily snapshots to retain
	TelegramToken string  // optional; enables the Telegram bot when set
	TelegramAdms  []int64 // Telegram chat IDs allowed to use the bot
}

type App struct {
	cfg   Config
	store *Store
	hub   *Hub

	loginLimiter *limiter

	activeMu    sync.Mutex
	activeCache map[int64]string

	metricsMu   sync.Mutex
	nodeMetrics map[int64]*wire.NodeMetrics

	notifyMu        sync.Mutex
	userActive      map[int64]bool
	offlineNotified map[int64]bool

	// Live Telegram config, editable from the panel (DB overrides env).
	tgMu      sync.Mutex
	tgToken   string
	tgAdmins  []int64
	rootCtx   context.Context
	botCancel context.CancelFunc

	// Live panel config editable from the settings panel (DB overrides env).
	settings liveSettings
}

// currentTelegram returns the live Telegram token and admin chat IDs.
func (a *App) currentTelegram() (string, []int64) {
	a.tgMu.Lock()
	defer a.tgMu.Unlock()
	return a.tgToken, a.tgAdmins
}

// setTelegram updates the live Telegram config.
func (a *App) setTelegram(token string, admins []int64) {
	a.tgMu.Lock()
	a.tgToken = token
	a.tgAdmins = admins
	a.tgMu.Unlock()
}

// restartBot stops any running bot loop and starts a fresh one for the current
// token (or leaves it stopped when the token is empty).
func (a *App) restartBot() {
	a.tgMu.Lock()
	if a.botCancel != nil {
		a.botCancel()
		a.botCancel = nil
	}
	token := a.tgToken
	root := a.rootCtx
	a.tgMu.Unlock()
	if token == "" || root == nil {
		log.Printf("telegram bot stopped")
		return
	}
	ctx, cancel := context.WithCancel(root)
	a.tgMu.Lock()
	a.botCancel = cancel
	a.tgMu.Unlock()
	go a.startBot(ctx, token)
	log.Printf("telegram bot started")
}

func (a *App) setNodeMetrics(nodeID int64, m *wire.NodeMetrics) {
	a.metricsMu.Lock()
	a.nodeMetrics[nodeID] = m
	a.metricsMu.Unlock()
}

func (a *App) getNodeMetrics(nodeID int64) *wire.NodeMetrics {
	a.metricsMu.Lock()
	defer a.metricsMu.Unlock()
	return a.nodeMetrics[nodeID]
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(key))) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return def
	}
}

func envInt(key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

// ConfigFromEnv builds panel config from environment variables.
func ConfigFromEnv() Config {
	publicURL := env("PANEL_PUBLIC_URL", "http://localhost:8088")
	return Config{
		Listen:        env("PANEL_LISTEN", ":8088"),
		DBPath:        env("PANEL_DB_PATH", "/data/panel.db"),
		JWTSecret:     env("PANEL_JWT_SECRET", ""),
		AdminUser:     env("PANEL_ADMIN_USER", "admin"),
		AdminPass:     env("PANEL_ADMIN_PASS", "admin"),
		PublicURL:     publicURL,
		CookieSecure:  envBool("PANEL_COOKIE_SECURE", strings.HasPrefix(strings.ToLower(publicURL), "https://")),
		AllowWeakPass: envBool("PANEL_ALLOW_WEAK_PASS", false),
		BackupDir:     env("PANEL_BACKUP_DIR", "/data/backups"),
		BackupKeep:    envInt("PANEL_BACKUP_KEEP", 7),
		TelegramToken: env("TELEGRAM_BOT_TOKEN", ""),
		TelegramAdms:  parseIDList(env("TELEGRAM_ADMIN_IDS", "")),
	}
}

// validateSecrets fails closed on weak/default credentials.
func validateSecrets(cfg Config) error {
	if !cfg.AllowWeakPass {
		if err := validatePasswordStrength(cfg.AdminPass); err != nil {
			return fmt.Errorf("PANEL_ADMIN_PASS is too weak: %w "+
				"(or set PANEL_ALLOW_WEAK_PASS=1 to override for local testing)", err)
		}
	}
	if cfg.JWTSecret != "" && (cfg.JWTSecret == "replace-with-64-hex-chars" || len(cfg.JWTSecret) < 16) {
		return fmt.Errorf("PANEL_JWT_SECRET is the placeholder or too short (<16 chars); " +
			"generate one with: openssl rand -hex 32")
	}
	return nil
}

func parseIDList(s string) []int64 {
	var out []int64
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if id, err := strconv.ParseInt(p, 10, 64); err == nil {
			out = append(out, id)
		}
	}
	return out
}

// Run starts the panel and blocks.
func Run(cfg Config) error {
	if err := validateSecrets(cfg); err != nil {
		return err
	}
	if cfg.JWTSecret == "" {
		cfg.JWTSecret = randToken(32)
		log.Printf("PANEL_JWT_SECRET not set; generated an ephemeral one (sessions reset on restart)")
	}

	store, err := OpenStore(cfg.DBPath)
	if err != nil {
		return err
	}
	defer store.Close()

	hash, err := hashPassword(cfg.AdminPass)
	if err != nil {
		return err
	}
	if err := store.EnsureAdmin(cfg.AdminUser, hash); err != nil {
		return err
	}

	app := &App{
		cfg:             cfg,
		store:           store,
		activeCache:     map[int64]string{},
		nodeMetrics:     map[int64]*wire.NodeMetrics{},
		userActive:      map[int64]bool{},
		offlineNotified: map[int64]bool{},
		loginLimiter:    newLimiter(8, 5*time.Minute),
	}
	app.hub = NewHub(app)
	app.loadSettings(cfg.PublicURL, cfg.BackupKeep)
	if !app.cookieSecure() {
		log.Printf("warning: session cookie is not marked Secure (public URL is not https); serve the panel over TLS in production, or set cookie security to 'on' in Settings")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	app.rootCtx = ctx
	go app.enforcementLoop(ctx)
	go app.autoResetLoop(ctx)
	go app.backupLoop(ctx, cfg.BackupDir)

	// Load Telegram config: a value set in the panel (DB) overrides the env seed.
	tok := cfg.TelegramToken
	if v, found, _ := store.GetSetting("telegram_token"); found {
		tok = v
	}
	adm := cfg.TelegramAdms
	if v, found, _ := store.GetSetting("telegram_admin_ids"); found {
		adm = parseIDList(v)
	}
	app.setTelegram(tok, adm)
	app.restartBot()

	mux := http.NewServeMux()

	// Unauthenticated liveness probe (no secrets, no state).
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("GET /api/node/ws", app.hub.handleWS)

	mux.HandleFunc("POST /api/login", app.handleLogin)
	mux.HandleFunc("POST /api/logout", app.handleLogout)
	mux.HandleFunc("POST /api/logout-all", app.requireAuth(app.handleLogoutAll))
	mux.HandleFunc("GET /api/me", app.requireAuth(app.handleMe))

	mux.HandleFunc("GET /api/nodes", app.requireAuth(app.handleListNodes))
	mux.HandleFunc("POST /api/nodes", app.requireAuth(app.handleCreateNode))
	mux.HandleFunc("PUT /api/nodes/{id}", app.requireAuth(app.handleUpdateNode))
	mux.HandleFunc("DELETE /api/nodes/{id}", app.requireAuth(app.handleDeleteNode))
	mux.HandleFunc("GET /api/nodes/{id}/install", app.requireAuth(app.handleNodeInstall))
	mux.HandleFunc("POST /api/reality-keys", app.requireAuth(app.handleRealityKeys))
	mux.HandleFunc("GET /api/backup", app.requireAuth(app.handleBackup))

	mux.HandleFunc("GET /api/2fa", app.requireAuth(app.handle2FAStatus))
	mux.HandleFunc("POST /api/2fa/setup", app.requireAuth(app.handle2FASetup))
	mux.HandleFunc("POST /api/2fa/verify", app.requireAuth(app.handle2FAVerify))
	mux.HandleFunc("POST /api/2fa/disable", app.requireAuth(app.handle2FADisable))
	mux.HandleFunc("GET /api/2fa/qr", app.requireAuth(app.handle2FAQR))

	mux.HandleFunc("GET /api/admins", app.requireAuth(app.handleListAdmins))
	mux.HandleFunc("POST /api/admins", app.requireAuth(app.handleCreateAdmin))
	mux.HandleFunc("DELETE /api/admins/{username}", app.requireAuth(app.handleDeleteAdmin))
	mux.HandleFunc("POST /api/admins/{username}/password", app.requireAuth(app.handleChangeAdminPassword))
	mux.HandleFunc("GET /api/audit", app.requireAuth(app.handleListAudit))

	mux.HandleFunc("GET /api/notify", app.requireAuth(app.handleNotifyStatus))
	mux.HandleFunc("PUT /api/notify", app.requireAuth(app.handleNotifySettings))
	mux.HandleFunc("POST /api/notify/test", app.requireAuth(app.handleNotifyTest))

	mux.HandleFunc("GET /api/settings", app.requireAuth(app.handleGetSettings))
	mux.HandleFunc("PUT /api/settings", app.requireAuth(app.handlePutSettings))

	mux.HandleFunc("GET /api/users", app.requireAuth(app.handleListUsers))
	mux.HandleFunc("POST /api/users", app.requireAuth(app.handleCreateUser))
	mux.HandleFunc("PUT /api/users/{id}", app.requireAuth(app.handleUpdateUser))
	mux.HandleFunc("DELETE /api/users/{id}", app.requireAuth(app.handleDeleteUser))
	mux.HandleFunc("POST /api/users/{id}/nodes", app.requireAuth(app.handleSetUserNodes))
	mux.HandleFunc("POST /api/users/{id}/reset-traffic", app.requireAuth(app.handleResetUserTraffic))
	mux.HandleFunc("GET /api/users/{id}/sub", app.requireAuth(app.handleUserSubInfo))
	mux.HandleFunc("GET /api/users/{id}/traffic-history", app.requireAuth(app.handleUserTrafficHistory))
	mux.HandleFunc("GET /api/users/{id}/devices", app.requireAuth(app.handleUserDevices))
	mux.HandleFunc("POST /api/users/{id}/rotate-sub", app.requireAuth(app.handleRotateSub))
	mux.HandleFunc("POST /api/users/{id}/rotate-uuid", app.requireAuth(app.handleRotateUUID))
	mux.HandleFunc("POST /api/users/{id}/portal-password", app.requireAuth(app.handleSetPortalPassword))

	mux.HandleFunc("GET /sub/{token}", app.handleSub)
	mux.HandleFunc("GET /sub/{token}/clash", app.handleSubClash)
	mux.HandleFunc("GET /sub/{token}/singbox", app.handleSubSingbox)

	// Self-service user portal (public; users authenticate with their own
	// portal password, held in a separate cookie/role from the admin session).
	mux.HandleFunc("GET /portal", app.handlePortalPage)
	mux.HandleFunc("POST /api/portal/login", app.handlePortalLogin)
	mux.HandleFunc("POST /api/portal/logout", app.handlePortalLogout)
	mux.HandleFunc("GET /api/portal/me", app.handlePortalMe)
	mux.HandleFunc("POST /api/portal/change-password", app.handlePortalChangePassword)
	mux.HandleFunc("GET /api/portal/qr", app.handlePortalQR)

	sub, _ := fs.Sub(webFS, "web")
	mux.Handle("GET /", http.FileServer(http.FS(sub)))

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           securityHeaders(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Serve, then shut down gracefully on SIGINT/SIGTERM: stop background loops,
	// stop accepting new connections, and let in-flight requests finish.
	errc := make(chan error, 1)
	go func() {
		log.Printf("panel listening on %s (public %s)", cfg.Listen, app.publicURL())
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errc <- err
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-errc:
		return err
	case <-sig:
		log.Printf("shutting down…")
		cancel()
		shCtx, shCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shCancel()
		return srv.Shutdown(shCtx)
	}
}
