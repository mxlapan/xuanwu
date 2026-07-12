package agent

import (
	"context"
	"log"
	"os"
	"os/exec"
	"strings"
	"time"
)

// watchCert re-applies the config when the TLS cert file changes, picking up a
// renewed or newly-issued cert (and re-enabling TLS-Vision if it had been dropped
// for lack of a cert). The initial mtime is the baseline, so boot is quiet.
func (c *Config) watchCert(ctx context.Context) {
	if c.CertPath == "" {
		return
	}
	stamp := func() (time.Time, int64) {
		fi, err := os.Stat(c.CertPath)
		if err != nil {
			return time.Time{}, 0
		}
		return fi.ModTime(), fi.Size()
	}
	lastT, lastS := stamp()
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			mt, sz := stamp()
			if mt.IsZero() {
				continue
			}
			if mt.After(lastT) || sz != lastS {
				lastT, lastS = mt, sz
				// Re-apply the last config (re-adds TLS-Vision now a cert exists);
				// fall back to a plain restart if no config arrived yet.
				if cfg := c.getLastConfig(); len(cfg) > 0 {
					log.Printf("tls cert changed (%s); re-applying config", c.CertPath)
					if err := c.applyConfig(cfg); err != nil {
						log.Printf("cert reload re-apply failed: %v", err)
					}
					continue
				}
				log.Printf("tls cert changed (%s); restarting %s", c.CertPath, c.XrayContainer)
				if out, err := exec.Command("docker", "restart", c.XrayContainer).CombinedOutput(); err != nil {
					log.Printf("cert reload restart failed: %v: %s", err, strings.TrimSpace(string(out)))
				}
			}
		}
	}
}
