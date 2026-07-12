# Panel ↔ Agent protocol

Transport: a single **outbound** WebSocket from the Agent to the Panel at
`GET {PANEL_URL}/api/node/ws`. The Agent authenticates by sending a `register`
frame with its node token first. All frames are JSON objects with a `type`
field (see `internal/wire`).

## Agent → Panel

```jsonc
// first frame — authenticates the connection
{ "type": "register", "token": "<node token>", "version": "2.0.0" }

// periodic liveness + node health (every ~20s)
{ "type": "heartbeat", "metrics": {
    "load_avg": 0.21, "mem_used_pct": 14,
    "xray_version": "26.6.27", "cert_expiry": 1815317059, "uptime": 1972
} }

// traffic batch; seq correlates with the panel's ack (see Durability)
{ "type": "traffic", "seq": 42, "items": [
    { "email": "alice", "up": 12345, "down": 67890 }
] }

// client devices seen since the last report (source IP + inbound type only)
{ "type": "devices", "devices": [
    { "email": "alice", "ip": "203.0.113.5", "inbound": "reality",
      "conns": 2, "last_seen": 1783759770 }
] }
```

## Panel → Agent

```jsonc
// sent right after a successful register, and whenever the node's effective
// user set / settings change. Full Xray config, not a diff. tls_domain (optional)
// is the node's TLS domain; the Agent publishes it for the acme sidecar to issue
// a cert, so managed nodes never repeat it in .env.
{ "type": "config", "config": { /* full Xray config.json object */ }, "tls_domain": "node.example.com" }

// acknowledges a traffic batch by seq
{ "type": "ack", "seq": 42 }
```

## Reconnection

The Agent reconnects with exponential backoff (1s → 30s cap). On every
(re)connect it re-registers and the Panel re-pushes the current config, so the
node is eventually consistent with Panel state.

## Traffic durability (exactly-once-ish)

Xray's stats are read **and reset** each interval, so once collected the bytes
exist only in the Agent until the Panel confirms them:

- The Agent keeps a **durable, disk-persisted buffer**. A batch is sent under a
  monotonically increasing `seq` and **resent until acked**; only then is it
  cleared. An Agent restart or a dropped connection therefore never loses a
  window.
- The Panel records the **last applied `seq` per node** and ignores duplicates
  (a resend equal to the last seq). A `seq` lower than the last applied means the
  Agent restarted with a fresh buffer, and the Panel re-baselines. This gives
  effectively exactly-once accounting across reconnects and restarts on either
  side.

## Config application (restart-free when possible)

The Agent writes the received config to the shared `config.json` volume, then:

- **Live path** — if only the user set changed, it applies the delta to the
  running Xray over its gRPC `HandlerService` (`AlterInbound` add/remove user) —
  **no restart, no dropped connections**.
- **Restart path** — if non-user settings changed (or the live path fails), it
  restarts the `xray` container via the mounted Docker socket, then records the
  new baseline.

A separate watcher re-applies the config when the **TLS certificate file**
changes (renewals, or a first-time cert enabling TLS-Vision), independent of
config pushes.

## Traffic accounting source

Every `STATS_INTERVAL` seconds the Agent runs, inside the xray container:

```
xray api statsquery --server=127.0.0.1:10085 -pattern "user>>>" -reset
```

Stat names look like `user>>>alice>>>traffic>>>uplink`. The Agent groups by email
into the durable buffer. The Panel adds increments to each user's `data_used`
(scoped to users actually assigned to the reporting node), then enforces
`data_limit` / `expire_at` / enabled: over-quota, expired or disabled users are
dropped from generated configs and a fresh `config` frame is pushed.

## Device tracking source

The Agent tails the Xray **access log** (`XRAY_ACCESS_LOG`), extracting per-user
**source IP** and **inbound type** (reality/tls) only — never the browsing
destination. The source IP is the **real client IP**: nginx sends the PROXY
protocol to xray (`proxy_protocol on;`) and the inbounds accept it
(`acceptProxyProtocol`), so xray logs the client rather than the nginx container.
Reports are scoped to the reporting node's assigned users. See
[users.md](users.md#devices-admin-only).
