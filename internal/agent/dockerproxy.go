package agent

import (
	"context"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// The docker proxy is a hardened, allow-listed reverse proxy in front of the
// Docker socket. Instead of the agent mounting /var/run/docker.sock directly
// (which is root-equivalent on the host and would let a compromised agent create
// a privileged container to escape), only this tiny process mounts the socket
// and forwards nothing but the two operations the agent actually needs: inspect
// and restart, on named containers. The agent reaches it via DOCKER_HOST.

// reProxyPath matches the forwardable container operations, with an optional
// /v1.xx API-version prefix:
//
//	GET  /containers/{name}/json     (inspect)
//	POST /containers/{name}/restart  (restart)
var reProxyPath = regexp.MustCompile(`^(?:/v[0-9]+\.[0-9]+)?/containers/([a-zA-Z0-9_.-]+)/(json|restart)$`)

// reProbe matches the Docker CLI's read-only version-negotiation probes.
var reProbe = regexp.MustCompile(`^(?:/v[0-9]+\.[0-9]+)?/(?:_ping|version)$`)

type dockerProxy struct {
	allowed map[string]bool // container names the agent may inspect/restart
	rp      *httputil.ReverseProxy
}

// allow decides whether a request may reach the Docker socket. Only inspect and
// restart on explicitly allow-listed containers, plus read-only ping/version
// probes, are permitted; everything else — create, exec, attach, images,
// volumes, container listing, deletion — is refused.
func (p *dockerProxy) allow(method, path string) bool {
	if (method == http.MethodGet || method == http.MethodHead) && reProbe.MatchString(path) {
		return true
	}
	m := reProxyPath.FindStringSubmatch(path)
	if m == nil || !p.allowed[m[1]] {
		return false
	}
	switch m[2] {
	case "json":
		return method == http.MethodGet || method == http.MethodHead
	case "restart":
		return method == http.MethodPost
	}
	return false
}

func (p *dockerProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !p.allow(r.Method, r.URL.Path) {
		log.Printf("dockerproxy: deny %s %s", r.Method, r.URL.Path)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	p.rp.ServeHTTP(w, r)
}

// RunDockerProxy serves the allow-listed proxy until killed. It is wired up as
// the `dockerproxy` subcommand and run in its own container that holds the only
// mount of the Docker socket.
func RunDockerProxy() error {
	sock := env("DOCKER_SOCKET", "/var/run/docker.sock")
	listen := env("DOCKERPROXY_LISTEN", ":2375")
	allowed := map[string]bool{}
	for _, n := range strings.Split(env("DOCKERPROXY_ALLOW", "xray,nginx-edge"), ",") {
		if n = strings.TrimSpace(n); n != "" {
			allowed[n] = true
		}
	}

	target, _ := url.Parse("http://docker")
	rp := httputil.NewSingleHostReverseProxy(target)
	rp.Transport = &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", sock)
		},
	}

	srv := &http.Server{
		Addr:              listen,
		Handler:           &dockerProxy{allowed: allowed, rp: rp},
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("dockerproxy listening on %s -> %s (inspect/restart only)", listen, sock)
	return srv.ListenAndServe()
}
