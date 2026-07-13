package agent

import (
	"bufio"
	"crypto/x509"
	"encoding/pem"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"xuanwu/internal/wire"
)

var startTime = time.Now()

// collectMetrics gathers a lightweight node health snapshot for a heartbeat.
func (c *Config) collectMetrics() *wire.NodeMetrics {
	return &wire.NodeMetrics{
		LoadAvg:     loadAvg1(),
		MemUsedPct:  memUsedPct(),
		XrayVersion: c.xrayVersion(),
		CertExpiry:  certExpiry(c.CertPath),
		Uptime:      int64(time.Since(startTime).Seconds()),
	}
}

func loadAvg1() float64 {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0
	}
	if f := strings.Fields(string(b)); len(f) > 0 {
		v, _ := strconv.ParseFloat(f[0], 64)
		return v
	}
	return 0
}

func memUsedPct() int {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0
	}
	defer f.Close()
	var total, avail int64
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "MemTotal:"):
			total = meminfoKB(line)
		case strings.HasPrefix(line, "MemAvailable:"):
			avail = meminfoKB(line)
		}
	}
	if total <= 0 {
		return 0
	}
	return int(float64(total-avail) / float64(total) * 100)
}

func meminfoKB(line string) int64 {
	fields := strings.Fields(line)
	if len(fields) >= 2 {
		v, _ := strconv.ParseInt(fields[1], 10, 64)
		return v
	}
	return 0
}

// xrayVersion caches the Xray version (it only changes on image upgrade) and
// refreshes it at most hourly. It reads the container's image reference via
// `docker inspect` and takes the tag, so it needs only inspect access — no
// `docker exec` into the container (see the docker proxy).
var (
	xrayVerMu  sync.Mutex
	xrayVerVal string
	xrayVerAt  time.Time
	xrayVerTTL = time.Hour
)

func (c *Config) xrayVersion() string {
	xrayVerMu.Lock()
	defer xrayVerMu.Unlock()
	if xrayVerVal != "" && time.Since(xrayVerAt) < xrayVerTTL {
		return xrayVerVal
	}
	out, err := exec.Command("docker", "inspect", "-f", "{{.Config.Image}}", c.XrayContainer).Output()
	if err == nil {
		if v := imageTag(string(out)); v != "" {
			xrayVerVal = v
			xrayVerAt = time.Now()
		}
	}
	return xrayVerVal
}

// imageTag extracts the tag from a container image reference, e.g.
// "ghcr.io/xtls/xray-core:26.6.27" -> "26.6.27". It returns "" for an untagged
// reference, a "latest" tag, or a digest pin (nothing meaningful to show).
func imageTag(ref string) string {
	ref = strings.TrimSpace(ref)
	if i := strings.LastIndexByte(ref, '@'); i >= 0 {
		ref = ref[:i] // drop a digest suffix
	}
	slash := strings.LastIndexByte(ref, '/')
	colon := strings.LastIndexByte(ref, ':')
	if colon <= slash { // no tag (a ':' in the host part is a port, not a tag)
		return ""
	}
	tag := ref[colon+1:]
	if tag == "latest" {
		return ""
	}
	return tag
}

// certExpiry returns the notAfter of the first cert in the PEM file, or 0.
func certExpiry(path string) int64 {
	if path == "" {
		return 0
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	for len(b) > 0 {
		var block *pem.Block
		block, b = pem.Decode(b)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		if cert, err := x509.ParseCertificate(block.Bytes); err == nil {
			return cert.NotAfter.Unix()
		}
	}
	return 0
}
