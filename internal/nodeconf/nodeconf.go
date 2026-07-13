// Package nodeconf builds the engine config.json used by every node. It is
// shared by the panel (which generates configs centrally and pushes them) and
// the agent in standalone mode (which generates its own config locally, with no
// panel).
package nodeconf

// Client is one provisioned VLESS user on a node.
type Client struct {
	UUID  string
	Email string
}

// NodeParams are the per-node settings needed to render the inbounds.
type NodeParams struct {
	RealityDest       string
	RealityServerName string
	RealityPrivateKey string
	RealityShortID    string
	// TLSDomain, when set, adds the TLS-Vision inbound (which needs a cert).
	// Empty means REALITY only — no certificate required.
	TLSDomain string
}

// Build returns the Xray config: an API/stats inbound, a REALITY-Vision inbound
// (:10443) and, only when p.TLSDomain is set, a TLS-Vision inbound (:10444).
func Build(p NodeParams, clients []Client) map[string]any {
	list := make([]any, 0, len(clients))
	for _, c := range clients {
		list = append(list, map[string]any{
			"id":    c.UUID,
			"email": c.Email,
			"flow":  "xtls-rprx-vision",
			"level": 0,
		})
	}

	apiInbound := map[string]any{
		// Xray's control API (StatsService + HandlerService, which can add
		// and remove users). It has NO authentication of its own, so its only
		// protection is network reachability: it binds 0.0.0.0 because the
		// agent runs in a separate container and reaches it over the private
		// docker network at xray:10085 for live (restart-free) user edits.
		// SECURITY: port 10085 must never be published to the host / internet.
		// The compose file exposes it only on the internal xuanwu-net.
		"tag":      "api",
		"listen":   "0.0.0.0",
		"port":     10085,
		"protocol": "dokodemo-door",
		"settings": map[string]any{"address": "127.0.0.1"},
	}

	tlsInbound := map[string]any{
		"tag":      "vless-xtls-vision",
		"listen":   "0.0.0.0",
		"port":     10444,
		"protocol": "vless",
		"settings": map[string]any{
			"clients":    list,
			"decryption": "none",
			"fallbacks":  []any{map[string]any{"dest": "nginx:8080", "xver": 0}},
		},
		"streamSettings": map[string]any{
			"network":  "tcp",
			"security": "tls",
			"sockopt":  map[string]any{"acceptProxyProtocol": true},
			"tlsSettings": map[string]any{
				"rejectUnknownSni": true,
				"minVersion":       "1.3",
				"alpn":             []string{"http/1.1"},
				"certificates": []any{map[string]any{
					"ocspStapling":    3600,
					"certificateFile": "/etc/xray/certs/fullchain.pem",
					"keyFile":         "/etc/xray/certs/privkey.pem",
				}},
			},
		},
		"sniffing": map[string]any{
			"enabled":      true,
			"destOverride": []string{"http", "tls", "quic"},
			"routeOnly":    true,
		},
	}

	realityInbound := map[string]any{
		"tag":      "vless-reality-vision",
		"listen":   "0.0.0.0",
		"port":     10443,
		"protocol": "vless",
		"settings": map[string]any{
			"clients":    list,
			"decryption": "none",
		},
		"streamSettings": map[string]any{
			"network":  "tcp",
			"security": "reality",
			"sockopt":  map[string]any{"acceptProxyProtocol": true},
			"realitySettings": map[string]any{
				"show":        false,
				"dest":        p.RealityDest,
				"xver":        0,
				"serverNames": []string{p.RealityServerName},
				"privateKey":  p.RealityPrivateKey,
				"shortIds":    []string{p.RealityShortID},
			},
		},
		"sniffing": map[string]any{
			"enabled":      true,
			"destOverride": []string{"http", "tls", "quic"},
			"routeOnly":    true,
		},
	}

	inbounds := []any{apiInbound}
	if p.TLSDomain != "" {
		inbounds = append(inbounds, tlsInbound)
	}
	inbounds = append(inbounds, realityInbound)

	return map[string]any{
		"log": map[string]any{
			"loglevel": "warning",
			"access":   "/var/log/xray/access.log",
			"error":    "",
		},
		"stats": map[string]any{},
		"api": map[string]any{
			"tag":      "api",
			"services": []string{"StatsService", "HandlerService"},
		},
		"policy": map[string]any{
			"levels": map[string]any{
				"0": map[string]any{
					"statsUserUplink":   true,
					"statsUserDownlink": true,
				},
			},
			"system": map[string]any{
				"statsInboundUplink":   true,
				"statsInboundDownlink": true,
			},
		},
		"inbounds": inbounds,
		"outbounds": []any{
			map[string]any{"tag": "direct", "protocol": "freedom", "settings": map[string]any{"domainStrategy": "UseIPv4"}},
			map[string]any{"tag": "block", "protocol": "blackhole"},
		},
		"routing": map[string]any{
			"domainStrategy": "AsIs",
			"rules": []any{
				map[string]any{"type": "field", "inboundTag": []string{"api"}, "outboundTag": "api"},
				map[string]any{"type": "field", "ip": []string{"geoip:private"}, "outboundTag": "block"},
				map[string]any{"type": "field", "domain": []string{"geosite:category-ads-all"}, "outboundTag": "block"},
			},
		},
	}
}
