package agent

import "testing"

func TestDockerProxyAllow(t *testing.T) {
	p := &dockerProxy{allowed: map[string]bool{"xray": true, "nginx-edge": true}}

	allow := []struct{ method, path string }{
		{"GET", "/containers/xray/json"},
		{"GET", "/v1.51/containers/xray/json"},
		{"POST", "/containers/xray/restart"},
		{"POST", "/v1.51/containers/nginx-edge/restart"},
		{"HEAD", "/_ping"},
		{"GET", "/version"},
		{"GET", "/v1.51/_ping"},
	}
	for _, c := range allow {
		if !p.allow(c.method, c.path) {
			t.Errorf("allow(%s %s) = false, want true", c.method, c.path)
		}
	}

	deny := []struct{ method, path string }{
		{"POST", "/containers/xray/exec"},              // exec — the escape we close
		{"POST", "/v1.51/containers/create"},           // create a privileged container
		{"POST", "/containers/other/restart"},          // not allow-listed
		{"GET", "/containers/other/json"},              // not allow-listed
		{"POST", "/images/create"},                     // pull image
		{"GET", "/containers/json"},                    // list all containers
		{"DELETE", "/containers/xray"},                 // delete
		{"POST", "/containers/xray/json"},              // inspect is GET-only
		{"GET", "/containers/xray/restart"},            // restart is POST-only
		{"POST", "/containers/xray/restart/../create"}, // path traversal attempt
		{"POST", "/_ping"},                             // probe is read-only
	}
	for _, c := range deny {
		if p.allow(c.method, c.path) {
			t.Errorf("allow(%s %s) = true, want false", c.method, c.path)
		}
	}
}

func TestImageTag(t *testing.T) {
	cases := map[string]string{
		"ghcr.io/xtls/xray-core:26.6.27\n": "26.6.27",
		"nginx:1.30.3-alpine":              "1.30.3-alpine",
		"localhost:5000/foo:v2":            "v2",
		"ghcr.io/xtls/xray-core:latest":    "", // uninformative
		"ghcr.io/xtls/xray-core":           "", // no tag
		"localhost:5000/foo":               "", // ':' is a registry port, not a tag
		"foo@sha256:abc123":                "", // digest pin
	}
	for ref, want := range cases {
		if got := imageTag(ref); got != want {
			t.Errorf("imageTag(%q) = %q, want %q", ref, got, want)
		}
	}
}
