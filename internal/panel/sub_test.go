package panel

import "testing"

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
