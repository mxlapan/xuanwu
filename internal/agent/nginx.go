package agent

import (
	"encoding/json"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The agent owns the node's nginx config: it generates nginx.conf from the
// REALITY serverName it knows (pushed by the panel in managed mode, or from env
// in standalone mode) and writes it to a shared file that nginx runs. This makes
// a managed node need only PANEL_URL + NODE_TOKEN — the panel is the single
// source of truth for SNI routing.

// nginxTmpl is the full nginx.conf minus the REALITY map entry (filled per node)
// and the load_module line (the nginx container prepends it, since the module
// path is image-specific). The decoy site uses a catch-all server_name.
const nginxTmpl = `user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

stream {
    upstream xray_tls_vision     { server xray:10444; }
    upstream xray_reality_vision { server xray:10443; }

    map $ssl_preread_server_name $xuanwu_stream_backend {
__REALITY_MAP__        default                xray_tls_vision;
    }

    server {
        listen 443;
        listen [::]:443;
        proxy_pass $xuanwu_stream_backend;
        ssl_preread on;
        proxy_protocol on;               # send the real client IP to xray
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        listen 8080;
        listen [::]:8080;
        server_name _;
        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ $uri.html =404;
        }
        location ~ /\. { deny all; }
    }
}
`

// nginxConf renders the config for a node whose REALITY inbound uses realitySNI.
// An empty realitySNI produces a TLS-only config (no REALITY map entry).
func nginxConf(realitySNI string) string {
	line := ""
	if realitySNI != "" {
		line = "        " + realitySNI + " xray_reality_vision;\n"
	}
	return strings.Replace(nginxTmpl, "__REALITY_MAP__", line, 1)
}

// applyNginx writes the nginx config if it changed and restarts nginx (only if
// it is already running; otherwise nginx picks up the new file when it starts).
func (c *Config) applyNginx(realitySNI string) {
	if c.NginxConf == "" {
		return
	}
	desired := nginxConf(realitySNI)
	if cur, err := os.ReadFile(c.NginxConf); err == nil && string(cur) == desired {
		return // unchanged — don't restart nginx
	}
	if err := os.MkdirAll(filepath.Dir(c.NginxConf), 0o755); err != nil {
		log.Printf("nginx: mkdir: %v", err)
		return
	}
	if err := os.WriteFile(c.NginxConf, []byte(desired), 0o644); err != nil {
		log.Printf("nginx: write config: %v", err)
		return
	}
	log.Printf("nginx config updated (reality sni=%q)", realitySNI)
	if nginxRunning(c.NginxContainer) {
		if out, err := exec.Command("docker", "restart", c.NginxContainer).CombinedOutput(); err != nil {
			log.Printf("nginx restart failed: %v: %s", err, strings.TrimSpace(string(out)))
		}
	}
}

func nginxRunning(name string) bool {
	out, err := exec.Command("docker", "inspect", "-f", "{{.State.Running}}", name).Output()
	return err == nil && strings.TrimSpace(string(out)) == "true"
}

// realitySNIFromConfig extracts the REALITY inbound's serverName from an Xray
// config, or "" if there is no REALITY inbound / no serverName.
func realitySNIFromConfig(raw json.RawMessage) string {
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil {
		return ""
	}
	inbounds, _ := m["inbounds"].([]any)
	for _, ib := range inbounds {
		inb, ok := ib.(map[string]any)
		if !ok || inb["tag"] != tagReality {
			continue
		}
		ss, _ := inb["streamSettings"].(map[string]any)
		rs, _ := ss["realitySettings"].(map[string]any)
		names, _ := rs["serverNames"].([]any)
		if len(names) > 0 {
			s, _ := names[0].(string)
			return s
		}
	}
	return ""
}
