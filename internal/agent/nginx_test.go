package agent

import (
	"strings"
	"testing"
)

func TestValidSNI(t *testing.T) {
	for _, s := range []string{"www.microsoft.com", "*.example.com", "a-b_c.d", "1.2.3.4"} {
		if !validSNI(s) {
			t.Errorf("validSNI(%q) = false, want true", s)
		}
	}
	for _, s := range []string{"", "has space", "evil;\n} server {", "a\nb", "semi;colon", "brace{"} {
		if validSNI(s) {
			t.Errorf("validSNI(%q) = true, want false", s)
		}
	}
}

func TestNginxConfDropsInvalidSNI(t *testing.T) {
	// A malicious serverName must not appear in the rendered config, and must not
	// add a reality map entry.
	evil := "evil.com;\n} server { listen 80;"
	out := nginxConf(evil)
	if strings.Contains(out, "listen 80;") || strings.Contains(out, "xray_reality_vision;\n        evil") {
		t.Fatalf("invalid SNI leaked into config:\n%s", out)
	}
	if strings.Contains(out, "evil.com") {
		t.Fatal("invalid SNI value present in config")
	}
	// A valid SNI is rendered into the reality map.
	good := nginxConf("www.example.com")
	if !strings.Contains(good, "www.example.com xray_reality_vision;") {
		t.Fatalf("valid SNI missing from config:\n%s", good)
	}
}
