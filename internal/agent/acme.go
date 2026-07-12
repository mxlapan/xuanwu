package agent

import (
	"log"
	"os"
	"path/filepath"
	"strings"
)

// writeACMEDomain publishes the node's TLS domain to a file the acme sidecar
// reads, so the panel (managed) or .env (standalone) is the single source.
func (c *Config) writeACMEDomain(domain string) {
	if c.ACMEDomainFile == "" {
		return
	}
	domain = strings.TrimSpace(domain)
	if cur, err := os.ReadFile(c.ACMEDomainFile); err == nil && strings.TrimSpace(string(cur)) == domain {
		return
	}
	if err := os.MkdirAll(filepath.Dir(c.ACMEDomainFile), 0o755); err != nil {
		log.Printf("acme domain: mkdir: %v", err)
		return
	}
	if err := os.WriteFile(c.ACMEDomainFile, []byte(domain+"\n"), 0o644); err != nil {
		log.Printf("acme domain: write: %v", err)
		return
	}
	if domain != "" {
		log.Printf("acme domain published: %q", domain)
	}
}
