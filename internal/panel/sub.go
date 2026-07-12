package panel

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

// nodeLinks returns a user's vless:// links on one node: a REALITY link (when the
// node has REALITY keys) and/or a TLS-Vision link (when it has a TLS domain).
func nodeLinks(u *User, n *Node) []string {
	var links []string
	esc := url.QueryEscape

	if n.RealityPublicKey != "" && n.RealityServerName != "" {
		host := n.Address
		if host == "" {
			host = n.RealityServerName
		}
		q := url.Values{}
		q.Set("encryption", "none")
		q.Set("flow", "xtls-rprx-vision")
		q.Set("security", "reality")
		q.Set("sni", n.RealityServerName)
		q.Set("fp", "chrome")
		q.Set("pbk", n.RealityPublicKey)
		if n.RealityShortID != "" {
			q.Set("sid", n.RealityShortID)
		}
		q.Set("type", "tcp")
		links = append(links, fmt.Sprintf("vless://%s@%s:443?%s#%s",
			u.UUID, host, q.Encode(), esc(n.Name+"-reality")))
	}

	if n.TLSDomain != "" {
		q := url.Values{}
		q.Set("encryption", "none")
		q.Set("flow", "xtls-rprx-vision")
		q.Set("security", "tls")
		q.Set("sni", n.TLSDomain)
		q.Set("fp", "chrome")
		q.Set("type", "tcp")
		links = append(links, fmt.Sprintf("vless://%s@%s:443?%s#%s",
			u.UUID, n.TLSDomain, q.Encode(), esc(n.Name+"-tls")))
	}
	return links
}

func (a *App) userNodesList(u *User) []*Node {
	var nodes []*Node
	for _, nid := range u.NodeIDs {
		if n, err := a.store.GetNode(nid); err == nil {
			nodes = append(nodes, n)
		}
	}
	return nodes
}

// handleSub serves the base64 vless subscription consumed by v2rayN/sing-box etc.
func (a *App) handleSub(w http.ResponseWriter, r *http.Request) {
	u, err := a.store.GetUserBySubToken(r.PathValue("token"))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	var all []string
	for _, n := range a.userNodesList(u) {
		all = append(all, nodeLinks(u, n)...)
	}
	body := strings.Join(all, "\n")

	// Report quota to clients that read these headers.
	if u.DataLimit > 0 {
		w.Header().Set("Subscription-Userinfo",
			fmt.Sprintf("upload=0; download=%d; total=%d; expire=%d", u.DataUsed, u.DataLimit, u.ExpireAt))
	}
	w.Header().Set("Profile-Update-Interval", "12")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(body))))
}

// singboxOutbounds builds the VLESS outbounds a user has across their nodes.
func singboxOutbounds(a *App, u *User) ([]map[string]any, []string) {
	var outs []map[string]any
	var names []string
	for _, n := range a.userNodesList(u) {
		if n.RealityPublicKey != "" && n.RealityServerName != "" {
			name := n.Name + "-reality"
			host := n.Address
			if host == "" {
				host = n.RealityServerName
			}
			names = append(names, name)
			outs = append(outs, map[string]any{
				"type": "vless", "tag": name, "server": host, "server_port": 443,
				"uuid": u.UUID, "flow": "xtls-rprx-vision", "packet_encoding": "xudp",
				"tls": map[string]any{
					"enabled": true, "server_name": n.RealityServerName,
					"utls":    map[string]any{"enabled": true, "fingerprint": "chrome"},
					"reality": map[string]any{"enabled": true, "public_key": n.RealityPublicKey, "short_id": n.RealityShortID},
				},
			})
		}
		if n.TLSDomain != "" {
			name := n.Name + "-tls"
			names = append(names, name)
			outs = append(outs, map[string]any{
				"type": "vless", "tag": name, "server": n.TLSDomain, "server_port": 443,
				"uuid": u.UUID, "flow": "xtls-rprx-vision", "packet_encoding": "xudp",
				"tls": map[string]any{
					"enabled": true, "server_name": n.TLSDomain,
					"utls": map[string]any{"enabled": true, "fingerprint": "chrome"},
				},
			})
		}
	}
	return outs, names
}

// handleSubSingbox serves a sing-box config profile for the user's nodes.
func (a *App) handleSubSingbox(w http.ResponseWriter, r *http.Request) {
	u, err := a.store.GetUserBySubToken(r.PathValue("token"))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	nodeOuts, names := singboxOutbounds(a, u)
	if len(names) == 0 {
		names = []string{"direct"}
	}
	outbounds := []map[string]any{
		{"type": "selector", "tag": "proxy", "outbounds": append(append([]string{}, names...), "auto"), "default": names[0]},
		{"type": "urltest", "tag": "auto", "outbounds": names, "url": "http://www.gstatic.com/generate_204", "interval": "5m"},
	}
	outbounds = append(outbounds, nodeOuts...)
	outbounds = append(outbounds,
		map[string]any{"type": "direct", "tag": "direct"},
		map[string]any{"type": "block", "tag": "block"},
		map[string]any{"type": "dns", "tag": "dns-out"},
	)
	cfg := map[string]any{
		"log": map[string]any{"level": "warn"},
		"dns": map[string]any{"servers": []map[string]any{{"tag": "google", "address": "tls://8.8.8.8"}}},
		"inbounds": []map[string]any{
			{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080},
		},
		"outbounds": outbounds,
		"route": map[string]any{
			"rules": []map[string]any{
				{"protocol": "dns", "outbound": "dns-out"},
				{"ip_is_private": true, "outbound": "direct"},
			},
			"final": "proxy",
		},
	}
	w.Header().Set("Profile-Update-Interval", "12")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(cfg)
}

// handleSubClash serves a minimal Mihomo/Clash.Meta config listing the user's
// nodes plus a select + url-test group.
// clashProxies returns one Clash proxy item ("- {...}", no leading indent) per
// variant a node offers, plus the proxy names for proxy-group membership.
func clashProxies(a *App, u *User) (items, names []string) {
	for _, n := range a.userNodesList(u) {
		if n.RealityPublicKey != "" && n.RealityServerName != "" {
			name := n.Name + "-reality"
			names = append(names, name)
			host := n.Address
			if host == "" {
				host = n.RealityServerName
			}
			items = append(items, fmt.Sprintf("- {name: %q, type: vless, server: %s, port: 443, uuid: %s, network: tcp, udp: true, tls: true, encryption: none, flow: xtls-rprx-vision, packet-encoding: xudp, servername: %s, client-fingerprint: chrome, skip-cert-verify: false, reality-opts: {public-key: %s, short-id: %q}}",
				name, host, u.UUID, n.RealityServerName, n.RealityPublicKey, n.RealityShortID))
		}
		if n.TLSDomain != "" {
			name := n.Name + "-tls"
			names = append(names, name)
			items = append(items, fmt.Sprintf("- {name: %q, type: vless, server: %s, port: 443, uuid: %s, network: tcp, udp: true, tls: true, encryption: none, flow: xtls-rprx-vision, packet-encoding: xudp, servername: %s, client-fingerprint: chrome, skip-cert-verify: false}",
				name, n.TLSDomain, u.UUID, n.TLSDomain))
		}
	}
	return items, names
}

// renderClashTemplate injects proxies and names into an operator's template.
// Placeholders are indentation-aware: {{PROXIES}} / {{PROXY_NAMES}} alone on a
// line expand to a YAML list indented to match; {{PROXY_NAMES}} used inline (e.g.
// inside `proxies: [ ... ]`) expands to a comma-separated list.
func renderClashTemplate(tpl string, items, names []string) string {
	quoted := make([]string, len(names))
	for i, n := range names {
		quoted[i] = fmt.Sprintf("%q", n)
	}
	var out []string
	for _, line := range strings.Split(tpl, "\n") {
		trimmed := strings.TrimSpace(line)
		indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
		switch {
		case trimmed == "{{PROXIES}}":
			for _, it := range items {
				out = append(out, indent+it)
			}
		case trimmed == "{{PROXY_NAMES}}":
			for _, q := range quoted {
				out = append(out, indent+"- "+q)
			}
		case strings.Contains(line, "{{PROXY_NAMES}}"):
			out = append(out, strings.ReplaceAll(line, "{{PROXY_NAMES}}", strings.Join(quoted, ", ")))
		case strings.Contains(line, "{{PROXIES}}"):
			out = append(out, strings.ReplaceAll(line, "{{PROXIES}}", strings.Join(items, " ")))
		default:
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

func (a *App) handleSubClash(w http.ResponseWriter, r *http.Request) {
	u, err := a.store.GetUserBySubToken(r.PathValue("token"))
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	items, names := clashProxies(a, u)
	if len(names) == 0 {
		names = []string{"DIRECT"}
	}

	var out string
	if tpl := a.clashTemplate(); strings.TrimSpace(tpl) != "" {
		out = renderClashTemplate(tpl, items, names)
	} else {
		quoted := make([]string, len(names))
		for i, n := range names {
			quoted[i] = fmt.Sprintf("%q", n)
		}
		list := strings.Join(quoted, ", ")
		var b strings.Builder
		b.WriteString("port: 7890\nsocks-port: 7891\nallow-lan: true\nmode: rule\nlog-level: info\n")
		b.WriteString("proxies:\n")
		for _, it := range items {
			b.WriteString("  " + it + "\n")
		}
		b.WriteString("proxy-groups:\n")
		fmt.Fprintf(&b, "  - {name: PROXY, type: select, proxies: [%s]}\n", list)
		fmt.Fprintf(&b, "  - {name: AUTO, type: url-test, url: 'http://www.gstatic.com/generate_204', interval: 300, proxies: [%s]}\n", list)
		b.WriteString("rules:\n  - GEOIP,private,DIRECT,no-resolve\n  - MATCH,PROXY\n")
		out = b.String()
	}

	w.Header().Set("Profile-Update-Interval", "12")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(out))
}
