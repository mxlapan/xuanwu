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
// refreshes it at most hourly, since it costs a docker exec.
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
	out, err := exec.Command("docker", "exec", c.XrayContainer, "xray", "version").Output()
	if err == nil {
		// first line looks like: "Xray 26.6.27 (...) ..."
		if fields := strings.Fields(strings.SplitN(string(out), "\n", 2)[0]); len(fields) >= 2 {
			xrayVerVal = fields[1]
			xrayVerAt = time.Now()
		}
	}
	return xrayVerVal
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
