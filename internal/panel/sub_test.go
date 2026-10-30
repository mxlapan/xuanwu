package panel

import (
	"strings"
	"testing"
)

func TestRenderClashTemplate(t *testing.T) {
	tpl := "proxies:\n  {{PROXIES}}\nproxy-groups:\n  - name: PROXY\n    proxies:\n      {{PROXY_NAMES}}\n"
	items := []string{`- {name: "a"}`, `- {name: "b"}`}
	got := renderClashTemplate(tpl, items, []string{"a", "b"})
	want := "proxies:\n  - {name: \"a\"}\n  - {name: \"b\"}\nproxy-groups:\n  - name: PROXY\n    proxies:\n      - \"a\"\n      - \"b\"\n"
	if got != want {
		t.Fatalf("block form:\ngot:\n%q\nwant:\n%q", got, want)
	}
	if inline := renderClashTemplate("g: [{{PROXY_NAMES}}]", nil, []string{"a", "b"}); inline != `g: ["a", "b"]` {
		t.Fatalf("inline form: got %q", inline)
	}
}

// REALITY links must dial the node itself — Address, else the TLS domain — and
// never the REALITY serverName, which is the camouflage site: a link to it makes
// clients handshake with the real site and time out.
func TestRealityHost(t *testing.T) {
	reality := func(n Node) *Node {
		n.RealityDest, n.RealityServerName, n.RealityPublicKey = "www.apple.com:443", "www.apple.com", "pub"
		return &n
	}
	cases := map[string]struct {
		n    *Node
		want string
	}{
		"address":             {reality(Node{Address: "1.2.3.4", TLSDomain: "node.example"}), "1.2.3.4"},
		"tls domain fallback": {reality(Node{TLSDomain: "node.example"}), "node.example"},
		"no dialable host":    {reality(Node{}), ""},
		"no target":           {&Node{Address: "1.2.3.4", RealityServerName: "www.apple.com", RealityPublicKey: "pub"}, ""},
		"no public key":       {&Node{Address: "1.2.3.4", RealityDest: "www.apple.com:443", RealityServerName: "www.apple.com"}, ""},
	}
	for name, c := range cases {
		if got := c.n.realityHost(); got != c.want {
			t.Errorf("%s: realityHost() = %q, want %q", name, got, c.want)
		}
	}
	u := &User{UUID: "uuid-1"}
	for _, l := range nodeLinks(u, reality(Node{Name: "n", TLSDomain: "node.example"})) {
		if strings.Contains(l, "@www.apple.com:") {
			t.Fatalf("link dials the camouflage site: %s", l)
		}
	}
}
