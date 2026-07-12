package xrayconf

import "testing"

func TestBuildInboundsAndClients(t *testing.T) {
	cfg := Build(
		NodeParams{RealityServerName: "sni.example", RealityPrivateKey: "pk", RealityShortID: "sid", TLSDomain: "tls.example"},
		[]Client{{UUID: "uuid-1", Email: "alice"}},
	)
	inbounds, ok := cfg["inbounds"].([]any)
	if !ok {
		t.Fatal("no inbounds")
	}
	tags := map[string]bool{}
	for _, ib := range inbounds {
		m := ib.(map[string]any)
		tag, _ := m["tag"].(string)
		tags[tag] = true
		// Both VLESS inbounds must carry the client.
		if tag == "vless-xtls-vision" || tag == "vless-reality-vision" {
			settings := m["settings"].(map[string]any)
			clients := settings["clients"].([]any)
			if len(clients) != 1 {
				t.Fatalf("%s: got %d clients want 1", tag, len(clients))
			}
			c := clients[0].(map[string]any)
			if c["id"] != "uuid-1" || c["email"] != "alice" || c["flow"] != "xtls-rprx-vision" {
				t.Fatalf("%s: bad client %v", tag, c)
			}
		}
	}
	for _, want := range []string{"api", "vless-xtls-vision", "vless-reality-vision"} {
		if !tags[want] {
			t.Fatalf("missing inbound tag %q", want)
		}
	}
}

// Without a TLS domain the node is REALITY-only: the TLS-Vision inbound (which
// would need a certificate and otherwise crash Xray) must be absent.
func TestBuildOmitsTLSWithoutDomain(t *testing.T) {
	cfg := Build(NodeParams{RealityServerName: "sni.example", RealityPrivateKey: "pk"}, nil)
	for _, ib := range cfg["inbounds"].([]any) {
		if tag, _ := ib.(map[string]any)["tag"].(string); tag == "vless-xtls-vision" {
			t.Fatal("TLS-Vision inbound present without a TLS domain")
		}
	}
}
