package agent

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAccessWatcherParse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "access.log")
	lines := "" +
		"2026/07/12 09:00:00.123 from 1.2.3.4:5678 accepted tcp:example.com:443 [vless-reality-vision -> direct] email: alice\n" +
		"2026/07/12 09:00:01.000 from 1.2.3.4:5679 accepted tcp:foo.com:443 [vless-reality-vision -> direct] email: alice\n" +
		"2026/07/12 09:00:02.000 from 5.6.7.8:1234 accepted tcp:bar.com:443 [vless-xtls-vision -> direct] email: bob\n"
	if err := os.WriteFile(path, []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}
	w := newAccessWatcher(path)
	got := w.collect()
	byKey := map[string]struct {
		inbound string
		conns   int64
	}{}
	for _, d := range got {
		byKey[d.Email+"|"+d.IP] = struct {
			inbound string
			conns   int64
		}{d.Inbound, d.Conns}
	}
	if v := byKey["alice|1.2.3.4"]; v.conns != 2 || v.inbound != "reality" {
		t.Fatalf("alice device = %+v, want conns=2 inbound=reality", v)
	}
	if v := byKey["bob|5.6.7.8"]; v.conns != 1 || v.inbound != "tls" {
		t.Fatalf("bob device = %+v, want conns=1 inbound=tls", v)
	}

	// Nothing new on a second call.
	if again := w.collect(); len(again) != 0 {
		t.Fatalf("expected no new devices, got %d", len(again))
	}

	// Appended line is picked up incrementally.
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString("2026/07/12 09:05:00.000 from 9.9.9.9:2222 accepted tcp:x.com:443 [vless-reality-vision -> direct] email: alice\n")
	f.Close()
	inc := w.collect()
	if len(inc) != 1 || inc[0].IP != "9.9.9.9" {
		t.Fatalf("incremental read = %+v", inc)
	}

	// Truncation (rotation) resets the offset.
	os.WriteFile(path, []byte("2026/07/12 10:00:00.000 from 2.2.2.2:1 accepted tcp:y:443 [vless-xtls-vision -> direct] email: bob\n"), 0o644)
	rot := w.collect()
	if len(rot) != 1 || rot[0].IP != "2.2.2.2" || rot[0].Email != "bob" {
		t.Fatalf("post-rotation read = %+v", rot)
	}
}
