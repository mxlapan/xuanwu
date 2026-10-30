package nodeconf

import "testing"

func TestBuildInboundsAndClients(t *testing.T) {
	cfg := Build(
		NodeParams{RealityDest: "sni.example:443", RealityServerName: "sni.example", RealityPrivateKey: "pk", RealityShortID: "sid", TLSDomain: "tls.example"},
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

// A node with no REALITY settings (TLS-only) must not render the REALITY
// inbound: Xray 26.10 refuses an empty target, and that failed start would take
// the TLS inbound down with it.
func TestBuildOmitsRealityWhenUnset(t *testing.T) {
	for name, p := range map[string]NodeParams{
		"none":      {TLSDomain: "tls.example"},
		"no target": {RealityServerName: "sni.example", RealityPrivateKey: "pk", TLSDomain: "tls.example"},
		"no key":    {RealityDest: "sni.example:443", RealityServerName: "sni.example", TLSDomain: "tls.example"},
	} {
		tags := map[string]bool{}
		for _, ib := range Build(p, nil)["inbounds"].([]any) {
			tag, _ := ib.(map[string]any)["tag"].(string)
			tags[tag] = true
		}
		if tags["vless-reality-vision"] {
			t.Errorf("%s: REALITY inbound present without full REALITY settings", name)
		}
		if !tags["vless-xtls-vision"] {
			t.Errorf("%s: TLS inbound missing", name)
		}
	}
}

// Xray 26.10 deprecated freedom.settings.domainStrategy (slated for removal);
// the direct outbound must set it via streamSettings.sockopt instead.
func TestBuildDirectOutboundUsesSockopt(t *testing.T) {
	cfg := Build(NodeParams{RealityServerName: "sni.example", RealityPrivateKey: "pk"}, nil)
	for _, ob := range cfg["outbounds"].([]any) {
		m := ob.(map[string]any)
		if m["tag"] != "direct" {
			continue
		}
		if _, ok := m["settings"]; ok {
			t.Fatalf("direct outbound still sets deprecated settings: %v", m["settings"])
		}
		so := m["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
		if so["domainStrategy"] != "UseIPv4" {
			t.Fatalf("sockopt.domainStrategy = %v, want UseIPv4", so["domainStrategy"])
		}
		return
	}
	t.Fatal("no direct outbound")
}
