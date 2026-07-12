package agent

import (
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"os"
	"time"

	"xuanwu/internal/xrayconf"
)

// standaloneEnv are the node's own REALITY/TLS parameters, read from the
// environment in standalone (panel-less) mode.
type standaloneEnv struct {
	usersFile         string
	address           string // public host/IP for links
	tlsDomain         string
	realityDest       string
	realityServerName string
	realityPrivateKey string
	realityPublicKey  string
	realityShortID    string
}

func loadStandaloneEnv() standaloneEnv {
	return standaloneEnv{
		usersFile:         env("XUANWU_USERS_FILE", "/data/users.json"),
		address:           env("ADDRESS", env("DOMAIN", "")),
		tlsDomain:         env("DOMAIN", ""),
		realityDest:       env("REALITY_DEST", ""),
		realityServerName: env("REALITY_SERVER_NAME", ""),
		realityPrivateKey: env("REALITY_PRIVATE_KEY", ""),
		realityPublicKey:  env("REALITY_PUBLIC_KEY", ""),
		realityShortID:    env("REALITY_SHORT_ID", ""),
	}
}

// applyStandalone regenerates config.json from the local user DB and reloads Xray.
func applyStandalone(c Config, se standaloneEnv) error {
	db, err := loadLocalDB(se.usersFile)
	if err != nil {
		return err
	}
	clients := make([]xrayconf.Client, 0, len(db.Users))
	for _, u := range db.Users {
		clients = append(clients, xrayconf.Client{UUID: u.UUID, Email: u.Name})
	}
	cfg := xrayconf.Build(xrayconf.NodeParams{
		RealityDest:       se.realityDest,
		RealityServerName: se.realityServerName,
		RealityPrivateKey: se.realityPrivateKey,
		RealityShortID:    se.realityShortID,
		TLSDomain:         se.tlsDomain,
	}, clients)
	raw, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	c.writeACMEDomain(se.tlsDomain)
	return c.applyConfig(raw)
}

// RunStandalone applies the local config and stays alive so the container keeps
// running and `docker exec` CLI commands work.
func RunStandalone(c Config) error {
	se := loadStandaloneEnv()
	if se.realityServerName == "" || se.realityPrivateKey == "" {
		log.Printf("warning: REALITY_SERVER_NAME / REALITY_PRIVATE_KEY not set; REALITY inbound will be invalid")
	}
	if err := applyStandalone(c, se); err != nil {
		return err
	}
	log.Printf("standalone node up; users file %s", se.usersFile)
	// idle loop; optionally sample stats for logging
	t := time.NewTicker(c.StatsInterval)
	defer t.Stop()
	for range t.C {
		_ = c.collectTraffic() // resets counters; discarded in standalone (no quota)
	}
	return nil
}

// RunCLI handles standalone user-management subcommands.
func RunCLI(c Config, args []string) error {
	se := loadStandaloneEnv()
	switch {
	case len(args) >= 3 && args[0] == "user" && args[1] == "add":
		return cliAddUser(c, se, args[2])
	case len(args) >= 3 && args[0] == "user" && args[1] == "rm":
		return cliRemoveUser(c, se, args[2])
	case len(args) >= 2 && args[0] == "user" && args[1] == "list":
		return cliListUsers(se)
	case len(args) >= 1 && args[0] == "apply":
		return applyStandalone(c, se)
	default:
		return fmt.Errorf("unknown command: %v", args)
	}
}

func cliAddUser(c Config, se standaloneEnv, name string) error {
	db, err := loadLocalDB(se.usersFile)
	if err != nil {
		return err
	}
	if db.find(name) >= 0 {
		return fmt.Errorf("user %q already exists", name)
	}
	u := localUser{Name: name, UUID: genUUID()}
	db.Users = append(db.Users, u)
	if err := saveLocalDB(se.usersFile, db); err != nil {
		return err
	}
	if err := applyStandalone(c, se); err != nil {
		return err
	}
	fmt.Printf("added user %s\n", name)
	for _, l := range shareLinks(se, u) {
		fmt.Println(l)
	}
	return nil
}

func cliRemoveUser(c Config, se standaloneEnv, name string) error {
	db, err := loadLocalDB(se.usersFile)
	if err != nil {
		return err
	}
	i := db.find(name)
	if i < 0 {
		return fmt.Errorf("user %q not found", name)
	}
	db.Users = append(db.Users[:i], db.Users[i+1:]...)
	if err := saveLocalDB(se.usersFile, db); err != nil {
		return err
	}
	if err := applyStandalone(c, se); err != nil {
		return err
	}
	fmt.Printf("removed user %s\n", name)
	return nil
}

func cliListUsers(se standaloneEnv) error {
	db, err := loadLocalDB(se.usersFile)
	if err != nil {
		return err
	}
	if len(db.Users) == 0 {
		fmt.Fprintln(os.Stderr, "no users")
		return nil
	}
	for _, u := range db.Users {
		fmt.Printf("%-20s %s\n", u.Name, u.UUID)
	}
	return nil
}

// shareLinks builds the vless:// links for a standalone user.
func shareLinks(se standaloneEnv, u localUser) []string {
	var links []string
	if se.realityPublicKey != "" && se.realityServerName != "" {
		host := se.address
		if host == "" {
			host = se.realityServerName
		}
		q := url.Values{}
		q.Set("encryption", "none")
		q.Set("flow", "xtls-rprx-vision")
		q.Set("security", "reality")
		q.Set("sni", se.realityServerName)
		q.Set("fp", "chrome")
		q.Set("pbk", se.realityPublicKey)
		if se.realityShortID != "" {
			q.Set("sid", se.realityShortID)
		}
		q.Set("type", "tcp")
		links = append(links, fmt.Sprintf("vless://%s@%s:443?%s#%s", u.UUID, host, q.Encode(), url.QueryEscape(u.Name+"-reality")))
	}
	if se.tlsDomain != "" {
		q := url.Values{}
		q.Set("encryption", "none")
		q.Set("flow", "xtls-rprx-vision")
		q.Set("security", "tls")
		q.Set("sni", se.tlsDomain)
		q.Set("fp", "chrome")
		q.Set("type", "tcp")
		links = append(links, fmt.Sprintf("vless://%s@%s:443?%s#%s", u.UUID, se.tlsDomain, q.Encode(), url.QueryEscape(u.Name+"-tls")))
	}
	return links
}
