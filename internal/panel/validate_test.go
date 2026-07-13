package panel

import (
	"net/http/httptest"
	"testing"
)

func TestValidateUsername(t *testing.T) {
	good := []string{"alice", "bob.smith", "u_1", "a-b-c", "ADMIN0"}
	for _, s := range good {
		if err := validateUsername(s); err != nil {
			t.Errorf("validateUsername(%q) rejected: %v", s, err)
		}
	}
	bad := []string{
		"",                       // empty
		"a b",                    // space
		"pipe|inject",            // breaks session token payload
		"a>>>traffic",            // breaks Xray stats key
		"drop;table",             // punctuation
		"emoji😀",                 // non-ascii
		"line\nbreak",            // control char
		string(make([]byte, 65)), // too long
	}
	for _, s := range bad {
		if err := validateUsername(s); err == nil {
			t.Errorf("validateUsername(%q) accepted, want reject", s)
		}
	}
}

func TestValidateNode(t *testing.T) {
	ok := []Node{
		{Name: "n"},
		{Address: "1.2.3.4", TLSDomain: "node.example.com"},
		{RealityServerName: "www.microsoft.com", RealityDest: "www.microsoft.com:443"},
		{RealityServerName: "*.example.com", RealityShortID: "0a1b2c3d", RealityPrivateKey: "aB3-_xyz", RealityPublicKey: "cD4-_abc"},
	}
	for i, n := range ok {
		if err := validateNode(&n); err != nil {
			t.Errorf("case %d: valid node rejected: %v", i, err)
		}
	}

	// serverName carrying an nginx directive break-out must be refused.
	inject := Node{RealityServerName: "evil.com;\n} server { listen 80"}
	if err := validateNode(&inject); err == nil {
		t.Fatal("nginx-injection serverName accepted")
	}
	bad := []Node{
		{Address: "has space"},
		{TLSDomain: "bad_\ndomain"},
		{RealityDest: "no-port"},
		{RealityDest: "host:99999"},
		{RealityDest: "host:abc"},
		{RealityShortID: "nothex!!"},
		{RealityPrivateKey: "has space in key"},
	}
	for i, n := range bad {
		if err := validateNode(&n); err == nil {
			t.Errorf("bad case %d accepted: %+v", i, n)
		}
	}
}

func TestCheckWSOrigin(t *testing.T) {
	// Agent: no Origin header -> allowed.
	r := httptest.NewRequest("GET", "http://panel.example/api/node/ws", nil)
	if !checkWSOrigin(r) {
		t.Fatal("agent (no Origin) rejected")
	}
	// Same-origin browser -> allowed.
	r = httptest.NewRequest("GET", "http://panel.example/api/node/ws", nil)
	r.Host = "panel.example"
	r.Header.Set("Origin", "http://panel.example")
	if !checkWSOrigin(r) {
		t.Fatal("same-origin rejected")
	}
	// Cross-origin browser -> rejected.
	r = httptest.NewRequest("GET", "http://panel.example/api/node/ws", nil)
	r.Host = "panel.example"
	r.Header.Set("Origin", "http://evil.example")
	if checkWSOrigin(r) {
		t.Fatal("cross-origin accepted")
	}
}
