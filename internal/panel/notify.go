package panel

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// notifyEnabled reports whether Telegram notifications are configured.
func (a *App) notifyEnabled() bool {
	token, admins := a.currentTelegram()
	return token != "" && len(admins) > 0
}

// Telegram config is stored in the settings table (keys telegram_token,
// telegram_admin_ids) and editable from the panel; the TELEGRAM_* env vars only
// seed the initial values. Live values are held in App.tg* and read via
// currentTelegram, so changes take effect without a panel restart.

// handleNotifyStatus reports Telegram configuration to the panel UI. It never
// returns the token itself, only whether one is set.
func (a *App) handleNotifyStatus(w http.ResponseWriter, r *http.Request) {
	token, admins := a.currentTelegram()
	ids := make([]int64, 0, len(admins))
	ids = append(ids, admins...)
	writeJSON(w, 200, map[string]any{
		"enabled":   token != "" && len(admins) > 0,
		"has_token": token != "",
		"admin_ids": ids,
		"events":    []string{"node offline", "node back online", "user disabled / over quota / expired"},
	})
}

// handleNotifySettings updates the Telegram token and/or admin IDs from the
// panel, persists them, and (re)starts the bot. A nil token keeps the current
// one; an empty token disables Telegram.
func (a *App) handleNotifySettings(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Token    *string `json:"token"`     // nil = keep, "" = clear, else set
		AdminIDs string  `json:"admin_ids"` // comma-separated chat IDs
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, 400, "bad body")
		return
	}
	curToken, _ := a.currentTelegram()
	newToken := curToken
	if body.Token != nil {
		newToken = strings.TrimSpace(*body.Token)
		if err := a.store.SetSecretSetting("telegram_token", newToken); err != nil {
			writeErr(w, 500, err.Error())
			return
		}
	}
	admins := parseIDList(body.AdminIDs)
	if err := a.store.SetSetting("telegram_admin_ids", body.AdminIDs); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	a.setTelegram(newToken, admins)
	a.restartBot()
	a.audit(r, "telegram.settings", fmt.Sprintf("token_set=%v admins=%d", newToken != "", len(admins)))
	a.handleNotifyStatus(w, r)
}

// handleNotifyTest sends a test message to the configured admins.
func (a *App) handleNotifyTest(w http.ResponseWriter, r *http.Request) {
	if !a.notifyEnabled() {
		writeErr(w, 400, "telegram not configured (set a bot token and at least one admin chat id)")
		return
	}
	a.notifyAdmins("🔔 Xuanwu test notification — your alerts are working.")
	writeJSON(w, 200, map[string]bool{"ok": true})
}

// notifyAdmins sends a message to every configured Telegram admin chat. It is a
// no-op when the bot isn't configured.
func (a *App) notifyAdmins(text string) {
	token, admins := a.currentTelegram()
	if token == "" || len(admins) == 0 {
		return
	}
	base := "https://api.telegram.org/bot" + token
	client := &http.Client{Timeout: 15 * time.Second}
	for _, id := range admins {
		payload, _ := json.Marshal(map[string]any{"chat_id": id, "text": text, "disable_web_page_preview": true})
		if resp, err := client.Post(base+"/sendMessage", "application/json", bytes.NewReader(payload)); err == nil {
			resp.Body.Close()
		}
	}
}

// noticeOnline reports a node coming back after it was reported offline.
func (a *App) noticeOnline(nodeID int64, name string) {
	a.notifyMu.Lock()
	was := a.offlineNotified[nodeID]
	delete(a.offlineNotified, nodeID)
	a.notifyMu.Unlock()
	if was {
		a.notifyAdmins("✅ Node back online: " + name)
	}
}

// scheduleOfflineNotice notifies once a node has been disconnected for a grace
// period without reconnecting (so routine restarts stay quiet).
func (h *Hub) scheduleOfflineNotice(nodeID int64) {
	time.AfterFunc(90*time.Second, func() {
		h.mu.RLock()
		_, online := h.conns[nodeID]
		h.mu.RUnlock()
		if online {
			return
		}
		n, err := h.app.store.GetNode(nodeID)
		if err != nil {
			return
		}
		h.app.notifyMu.Lock()
		h.app.offlineNotified[nodeID] = true
		h.app.notifyMu.Unlock()
		h.app.notifyAdmins(fmt.Sprintf("⚠️ Node offline: %s (%s)", n.Name, n.Address))
	})
}

// checkUserTransitions notifies when a user flips from active to inactive
// (expired, over quota, or disabled), so operators learn about lapses.
func (a *App) checkUserTransitions() {
	users, err := a.store.ListUsers()
	if err != nil {
		return
	}
	now := time.Now().Unix()
	a.notifyMu.Lock()
	defer a.notifyMu.Unlock()
	for _, u := range users {
		active := u.active(now)
		prev, seen := a.userActive[u.ID]
		a.userActive[u.ID] = active
		if seen && prev && !active {
			reason := "disabled"
			switch {
			case !u.Enabled:
				reason = "disabled by admin"
			case u.ExpireAt > 0 && now >= u.ExpireAt:
				reason = "expired"
			case u.DataLimit > 0 && u.DataUsed >= u.DataLimit:
				reason = "over quota"
			}
			a.notifyAdmins(fmt.Sprintf("🔕 User inactive: %s (%s)", u.Username, reason))
		}
	}
}
