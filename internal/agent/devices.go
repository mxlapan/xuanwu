package agent

import (
	"bufio"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"xuanwu/internal/wire"
)

// The access-log watcher extracts per-user client devices (distinct source IPs)
// from Xray's access log. It deliberately records only device-identifying
// metadata — source IP and which inbound was used — never the browsing
// destination, which stays private to the user.

// Example access-log line:
//
//	2026/07/12 09:00:00.123 from 1.2.3.4:5678 accepted tcp:example.com:443 [vless-reality-vision -> direct] email: alice
var accessRe = regexp.MustCompile(`from (\[[0-9a-fA-F:]+\]|[0-9.]+):\d+ accepted [^ ]+ \[([^\] ]+)[^\]]*\] email: (.+?)\s*$`)

type accessWatcher struct {
	mu     sync.Mutex
	path   string
	offset int64
}

func newAccessWatcher(path string) *accessWatcher { return &accessWatcher{path: path} }

// inboundKind maps an Xray inbound tag to a short device characteristic.
func inboundKind(tag string) string {
	switch {
	case strings.Contains(tag, "reality"):
		return "reality"
	case strings.Contains(tag, "tls"):
		return "tls"
	default:
		return tag
	}
}

// collect reads new access-log lines and returns aggregated per-user devices
// since the last call. Handles truncation/rotation by resetting the offset when
// the file shrinks.
func (w *accessWatcher) collect() []wire.DeviceItem {
	if w.path == "" {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	fi, err := os.Stat(w.path)
	if err != nil {
		return nil
	}
	if fi.Size() < w.offset {
		w.offset = 0 // rotated/truncated
	}
	if fi.Size() == w.offset {
		return nil
	}
	f, err := os.Open(w.path)
	if err != nil {
		return nil
	}
	defer f.Close()
	if _, err := f.Seek(w.offset, 0); err != nil {
		return nil
	}

	type key struct{ email, ip string }
	agg := map[key]*wire.DeviceItem{}
	now := time.Now().Unix()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	var read int64
	for sc.Scan() {
		line := sc.Text()
		read += int64(len(line)) + 1
		m := accessRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		ip := strings.Trim(m[1], "[]")
		kind := inboundKind(m[2])
		email := strings.TrimSpace(m[3])
		if email == "" || email == "unknown" {
			continue
		}
		k := key{email, ip}
		d := agg[k]
		if d == nil {
			d = &wire.DeviceItem{Email: email, IP: ip, Inbound: kind, LastSeen: now}
			agg[k] = d
		}
		d.Conns++
		d.Inbound = kind
		d.LastSeen = now
	}
	w.offset += read

	if len(agg) == 0 {
		return nil
	}
	out := make([]wire.DeviceItem, 0, len(agg))
	for _, d := range agg {
		out = append(out, *d)
	}
	return out
}
