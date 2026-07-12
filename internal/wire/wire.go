// Package wire defines the JSON message protocol shared by the panel and the
// node agent over their WebSocket link. See docs/PROTOCOL.md.
package wire

import "encoding/json"

// Msg is the envelope for every frame in both directions.
type Msg struct {
	Type    string          `json:"type"`
	Token   string          `json:"token,omitempty"`
	Version string          `json:"version,omitempty"`
	Config  json.RawMessage `json:"config,omitempty"`
	// TLSDomain rides with a config push so the node can auto-issue its cert.
	TLSDomain string        `json:"tls_domain,omitempty"`
	Items     []TrafficItem `json:"items,omitempty"`
	// Seq correlates a traffic batch with its ack. The agent keeps a batch in a
	// durable buffer and only drops it once the panel acks that Seq, so a dropped
	// connection can't lose a reporting window. The panel dedups by Seq per node.
	Seq int64 `json:"seq,omitempty"`
	// Metrics rides along with heartbeats to report node health.
	Metrics *NodeMetrics `json:"metrics,omitempty"`
	// Devices reports per-user client devices observed since the last report.
	Devices []DeviceItem `json:"devices,omitempty"`
}

// DeviceItem is one observed client device (a distinct source IP) for a user,
// derived from the Xray access log. It carries no browsing-destination data.
type DeviceItem struct {
	Email    string `json:"email"`
	IP       string `json:"ip"`
	Inbound  string `json:"inbound"`   // reality | tls (which inbound it used)
	Conns    int64  `json:"conns"`     // connections seen in this window
	LastSeen int64  `json:"last_seen"` // unix seconds
}

// NodeMetrics is a node health snapshot reported with heartbeats.
type NodeMetrics struct {
	LoadAvg     float64 `json:"load_avg"`     // 1-minute load average
	MemUsedPct  int     `json:"mem_used_pct"` // 0-100
	XrayVersion string  `json:"xray_version"`
	CertExpiry  int64   `json:"cert_expiry"` // unix seconds; 0 = unknown
	Uptime      int64   `json:"uptime"`      // agent uptime seconds
}

// TrafficItem is one user's traffic increment since the previous report.
type TrafficItem struct {
	Email string `json:"email"`
	Up    int64  `json:"up"`
	Down  int64  `json:"down"`
}

// Message type constants.
const (
	TypeRegister  = "register"
	TypeHeartbeat = "heartbeat"
	TypeTraffic   = "traffic"
	TypeConfig    = "config"
	TypeAck       = "ack"
	TypeDevices   = "devices"
)
