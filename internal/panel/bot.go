package panel

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// startBot runs a minimal long-polling Telegram bot that manages users and nodes
// through the same store the web UI uses. Only authorized chat IDs may act. It
// stops when ctx is cancelled (e.g. the token changed in the panel).
func (a *App) startBot(ctx context.Context, token string) {
	base := "https://api.telegram.org/bot" + token
	client := &http.Client{Timeout: 60 * time.Second}
	var offset int64
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		updates, err := a.botGetUpdates(client, base, offset)
		if err != nil {
			time.Sleep(3 * time.Second)
			continue
		}
		for _, u := range updates {
			offset = u.UpdateID + 1
			if u.Message == nil || u.Message.Text == "" {
				continue
			}
			a.botHandle(client, base, u.Message.Chat.ID, u.Message.Text)
		}
	}
}

type tgUpdate struct {
	UpdateID int64 `json:"update_id"`
	Message  *struct {
		Text string `json:"text"`
		Chat struct {
			ID int64 `json:"id"`
		} `json:"chat"`
	} `json:"message"`
}

func (a *App) botGetUpdates(client *http.Client, base string, offset int64) ([]tgUpdate, error) {
	url := fmt.Sprintf("%s/getUpdates?timeout=30&offset=%d", base, offset)
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var body struct {
		OK     bool       `json:"ok"`
		Result []tgUpdate `json:"result"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	return body.Result, nil
}

func (a *App) botSend(client *http.Client, base string, chatID int64, text string) {
	payload, _ := json.Marshal(map[string]any{"chat_id": chatID, "text": text, "disable_web_page_preview": true})
	resp, err := client.Post(base+"/sendMessage", "application/json", bytes.NewReader(payload))
	if err != nil {
		log.Printf("tg send: %v", err)
		return
	}
	resp.Body.Close()
}

func (a *App) botAuthorized(chatID int64) bool {
	_, admins := a.currentTelegram()
	if len(admins) == 0 {
		return false // no allowlist configured => deny all, fail closed
	}
	for _, id := range admins {
		if id == chatID {
			return true
		}
	}
	return false
}

const botHelp = `Xuanwu panel bot commands:
/users — list users
/nodes — list nodes
/adduser <name> [limitGB] [days] — create user
/deluser <name>
/enable <name> | /disable <name>
/traffic <name>
/reset <name> — reset traffic counter
/sub <name> — show subscription link`

func (a *App) botHandle(client *http.Client, base string, chatID int64, text string) {
	if !a.botAuthorized(chatID) {
		a.botSend(client, base, chatID, fmt.Sprintf("Unauthorized. Your chat id is %d; add it in the panel (Security → Telegram).", chatID))
		return
	}
	fields := strings.Fields(text)
	if len(fields) == 0 {
		return
	}
	cmd := strings.ToLower(strings.TrimPrefix(fields[0], "/"))
	if i := strings.IndexByte(cmd, '@'); i >= 0 {
		cmd = cmd[:i] // strip @botname suffix
	}
	args := fields[1:]
	a.botSend(client, base, chatID, a.botExec(cmd, args))
}

// botExec runs a command and returns the reply text.
func (a *App) botExec(cmd string, args []string) string {
	switch cmd {
	case "start", "help":
		return botHelp
	case "users":
		return a.botListUsers()
	case "nodes":
		return a.botListNodes()
	case "adduser":
		return a.botAddUser(args)
	case "deluser":
		return a.botMutateUser(args, "del")
	case "enable":
		return a.botMutateUser(args, "enable")
	case "disable":
		return a.botMutateUser(args, "disable")
	case "reset":
		return a.botMutateUser(args, "reset")
	case "traffic":
		return a.botTraffic(args)
	case "sub":
		return a.botSub(args)
	default:
		return "unknown command; /help"
	}
}

func fmtBytes(n int64) string {
	f := float64(n)
	units := []string{"B", "KB", "MB", "GB", "TB"}
	i := 0
	for f >= 1024 && i < len(units)-1 {
		f /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d B", n)
	}
	return fmt.Sprintf("%.1f %s", f, units[i])
}

func (a *App) botListUsers() string {
	users, err := a.store.ListUsers()
	if err != nil {
		return "error: " + err.Error()
	}
	if len(users) == 0 {
		return "no users"
	}
	var b strings.Builder
	for _, u := range users {
		limit := "∞"
		if u.DataLimit > 0 {
			limit = fmtBytes(u.DataLimit)
		}
		state := "on"
		if !u.Enabled {
			state = "off"
		}
		fmt.Fprintf(&b, "%s [%s] %s/%s\n", u.Username, state, fmtBytes(u.DataUsed), limit)
	}
	return b.String()
}

func (a *App) botListNodes() string {
	nodes, err := a.store.ListNodes()
	if err != nil {
		return "error: " + err.Error()
	}
	if len(nodes) == 0 {
		return "no nodes"
	}
	online := a.hub.OnlineNodeIDs()
	var b strings.Builder
	for _, n := range nodes {
		st := "offline"
		if online[n.ID] {
			st = "online"
		}
		fmt.Fprintf(&b, "%s (%s) — %s\n", n.Name, n.Address, st)
	}
	return b.String()
}

func (a *App) botAddUser(args []string) string {
	if len(args) < 1 {
		return "usage: /adduser <name> [limitGB] [days]"
	}
	name := args[0]
	if err := validateUsername(name); err != nil {
		return "error: " + err.Error()
	}
	if _, err := a.store.GetUserByName(name); err == nil {
		return "user already exists"
	}
	var limit, expire int64
	if len(args) >= 2 {
		if gb, err := strconv.ParseFloat(args[1], 64); err == nil {
			limit = int64(gb * (1 << 30))
		}
	}
	if len(args) >= 3 {
		if days, err := strconv.Atoi(args[2]); err == nil && days > 0 {
			expire = time.Now().Add(time.Duration(days) * 24 * time.Hour).Unix()
		}
	}
	u := &User{Username: name, UUID: newUUID(), SubToken: randToken(18), DataLimit: limit, ExpireAt: expire, Enabled: true}
	id, err := a.store.CreateUser(u)
	if err != nil {
		return "error: " + err.Error()
	}
	// assign to all nodes by default
	nodes, _ := a.store.ListNodes()
	ids := make([]int64, 0, len(nodes))
	for _, n := range nodes {
		ids = append(ids, n.ID)
	}
	if len(ids) > 0 {
		_ = a.store.SetUserNodes(id, ids)
		for _, nid := range ids {
			a.syncNode(nid)
		}
	}
	return fmt.Sprintf("added %s\nsub: %s/sub/%s", name, a.publicURL(), u.SubToken)
}

func (a *App) botMutateUser(args []string, action string) string {
	if len(args) < 1 {
		return "usage: /" + action + " <name>"
	}
	u, err := a.store.GetUserByName(args[0])
	if err != nil {
		return "user not found"
	}
	u, _ = a.store.GetUser(u.ID) // load node assignments
	switch action {
	case "del":
		if err := a.store.DeleteUser(u.ID); err != nil {
			return "error: " + err.Error()
		}
	case "enable":
		u.Enabled = true
		_ = a.store.UpdateUser(u)
	case "disable":
		u.Enabled = false
		_ = a.store.UpdateUser(u)
	case "reset":
		_ = a.store.ResetUserTraffic(u.ID)
	}
	for _, nid := range u.NodeIDs {
		a.syncNode(nid)
	}
	return action + " ok: " + args[0]
}

func (a *App) botTraffic(args []string) string {
	if len(args) < 1 {
		return "usage: /traffic <name>"
	}
	u, err := a.store.GetUserByName(args[0])
	if err != nil {
		return "user not found"
	}
	limit := "∞"
	if u.DataLimit > 0 {
		limit = fmtBytes(u.DataLimit)
	}
	return fmt.Sprintf("%s: %s / %s used", u.Username, fmtBytes(u.DataUsed), limit)
}

func (a *App) botSub(args []string) string {
	if len(args) < 1 {
		return "usage: /sub <name>"
	}
	u, err := a.store.GetUserByName(args[0])
	if err != nil {
		return "user not found"
	}
	return fmt.Sprintf("%s/sub/%s", a.publicURL(), u.SubToken)
}
