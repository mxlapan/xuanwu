package agent

import (
	"encoding/json"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"xuanwu/internal/wire"
)

// writeConfig writes the config to the shared volume, overwriting in place so a
// bind-mounted single file keeps its inode.
func writeConfig(path string, raw json.RawMessage) ([]byte, error) {
	var obj any
	if err := json.Unmarshal(raw, &obj); err != nil {
		return nil, err
	}
	pretty, err := json.MarshalIndent(obj, "", "  ")
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, pretty, 0o644); err != nil {
		return nil, err
	}
	return pretty, nil
}

// stripTLSIfNoCert drops the TLS-Vision inbound when its cert is missing, so Xray
// still starts (REALITY only) instead of failing to load the whole config. The
// cert watcher re-applies the full config once a certificate appears.
func stripTLSIfNoCert(raw json.RawMessage, certPath string) json.RawMessage {
	if certPath == "" {
		return raw
	}
	if _, err := os.Stat(certPath); err == nil {
		return raw // cert present — keep the TLS inbound
	}
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil {
		return raw
	}
	inbounds, ok := m["inbounds"].([]any)
	if !ok {
		return raw
	}
	kept := make([]any, 0, len(inbounds))
	removed := false
	for _, ib := range inbounds {
		if inb, ok := ib.(map[string]any); ok && inb["tag"] == tagTLS {
			removed = true
			continue
		}
		kept = append(kept, ib)
	}
	if !removed {
		return raw
	}
	m["inbounds"] = kept
	b, err := json.Marshal(m)
	if err != nil {
		return raw
	}
	log.Printf("no TLS certificate at %s — running REALITY only (TLS-Vision disabled until a cert appears)", certPath)
	return b
}

// applyConfig persists the new config and reloads Xray. It first tries to apply
// only the user delta live over gRPC (no dropped connections); if the non-user
// parts changed or the live path fails, it falls back to a container restart.
func (c *Config) applyConfig(raw json.RawMessage) error {
	c.apply.mu.Lock()
	defer c.apply.mu.Unlock()
	c.setLastConfig(raw)
	raw = stripTLSIfNoCert(raw, c.CertPath)
	pretty, err := writeConfig(c.XrayConfig, raw)
	if err != nil {
		return err
	}
	// Keep nginx's SNI routing in sync with the pushed REALITY serverName.
	c.applyNginx(realitySNIFromConfig(raw))
	skel, clients, ok := parseClients(raw)
	if ok && c.liveApply(skel, clients) {
		log.Printf("config updated live over gRPC (%d bytes, no restart)", len(pretty))
		return nil
	}
	log.Printf("config updated (%d bytes); restarting %s", len(pretty), c.XrayContainer)
	out, err := exec.Command("docker", "restart", c.XrayContainer).CombinedOutput()
	if err != nil {
		log.Printf("docker restart failed: %v: %s", err, strings.TrimSpace(string(out)))
		return err
	}
	// After a restart, xray matches the new config; record it as the baseline
	// so the next user-only change can be applied live.
	if ok {
		c.live.set(skel, clients)
	}
	return nil
}

// collectTraffic reads and resets per-user counters from Xray's stats API.
func (c *Config) collectTraffic() []wire.TrafficItem {
	out, err := exec.Command("docker", "exec", c.XrayContainer,
		"xray", "api", "statsquery", "--server="+c.APIServer, "-pattern", "user>>>", "-reset").Output()
	if err != nil {
		log.Printf("statsquery failed: %v", err)
		return nil
	}
	return parseStats(out)
}

func parseStats(out []byte) []wire.TrafficItem {
	var resp struct {
		Stat []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		} `json:"stat"`
	}
	if err := json.Unmarshal(out, &resp); err != nil {
		log.Printf("parse stats: %v", err)
		return nil
	}
	type acc struct{ up, down int64 }
	byEmail := map[string]*acc{}
	for _, s := range resp.Stat {
		parts := strings.Split(s.Name, ">>>") // user>>>{email}>>>traffic>>>{uplink|downlink}
		if len(parts) != 4 || parts[0] != "user" || parts[2] != "traffic" {
			continue
		}
		v, _ := strconv.ParseInt(s.Value, 10, 64)
		if v == 0 {
			continue
		}
		a := byEmail[parts[1]]
		if a == nil {
			a = &acc{}
			byEmail[parts[1]] = a
		}
		if parts[3] == "uplink" {
			a.up += v
		} else if parts[3] == "downlink" {
			a.down += v
		}
	}
	items := make([]wire.TrafficItem, 0, len(byEmail))
	for email, a := range byEmail {
		items = append(items, wire.TrafficItem{Email: email, Up: a.up, Down: a.down})
	}
	return items
}
