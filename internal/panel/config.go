package panel

import (
	"time"

	"xuanwu/internal/xrayconf"
)

// buildXrayConfig maps a node's currently-active users to the shared Xray config
// generator. Only enabled, non-expired, under-quota users are provisioned.
func (a *App) buildXrayConfig(node *Node, users []*User) map[string]any {
	now := time.Now().Unix()
	clients := make([]xrayconf.Client, 0, len(users))
	for _, u := range users {
		if !u.active(now) {
			continue
		}
		clients = append(clients, xrayconf.Client{UUID: u.UUID, Email: u.Username})
	}
	return xrayconf.Build(xrayconf.NodeParams{
		RealityDest:       node.RealityDest,
		RealityServerName: node.RealityServerName,
		RealityPrivateKey: node.RealityPrivateKey,
		RealityShortID:    node.RealityShortID,
		TLSDomain:         node.TLSDomain,
	}, clients)
}
