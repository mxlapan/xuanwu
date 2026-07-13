package panel

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Input validation for operator-supplied identifiers. The goal is defence in
// depth against injection into downstream sinks that are not JSON: usernames end
// up in the signed session payload (pipe-delimited) and in Xray's `>>>`-delimited
// stats keys; node hostnames are written verbatim into the generated nginx.conf
// (an SNI map entry) and into YAML/link subscription formats. Restricting these
// to their natural character sets closes those channels.

var (
	// usernames: letters, digits and a few separators; no '|' (breaks session
	// tokens), no '>' (breaks stats keys), no whitespace/control characters.
	reUsername = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	// a hostname, wildcard SNI (*.example.com) or IP literal — no characters that
	// could break out of an nginx directive, a YAML scalar or a URL host.
	reHostname = regexp.MustCompile(`^(\*\.)?[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)
	// REALITY short id: up to 16 hex chars (8 bytes), or empty.
	reShortID = regexp.MustCompile(`^[0-9a-fA-F]{0,16}$`)
	// base64 (std or url) key material, or empty.
	reB64Key = regexp.MustCompile(`^[A-Za-z0-9+/_=-]{0,128}$`)
)

// validateUsername enforces the identifier charset shared by admin and proxy
// user names.
func validateUsername(name string) error {
	if !reUsername.MatchString(name) {
		return fmt.Errorf("username must be 1-64 chars of letters, digits, '.', '_' or '-'")
	}
	return nil
}

// validHostname reports whether s is a safe hostname / wildcard SNI / IP.
func validHostname(s string) bool { return reHostname.MatchString(s) }

// validateNode checks the network-identifier fields of a node that flow into
// generated configs. Free-text fields (name, remark) are not restricted here;
// they are HTML-escaped at render time and never reach a config sink.
func validateNode(n *Node) error {
	if n.Address != "" && !validHostname(n.Address) {
		return fmt.Errorf("address must be a hostname or IP")
	}
	if n.TLSDomain != "" && !validHostname(n.TLSDomain) {
		return fmt.Errorf("tls_domain must be a hostname")
	}
	if n.RealityServerName != "" && !validHostname(n.RealityServerName) {
		return fmt.Errorf("reality_server_name must be a hostname")
	}
	if n.RealityDest != "" {
		host, port, ok := strings.Cut(n.RealityDest, ":")
		if !ok || !validHostname(host) {
			return fmt.Errorf("reality_dest must be host:port")
		}
		if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
			return fmt.Errorf("reality_dest port must be 1-65535")
		}
	}
	if !reShortID.MatchString(n.RealityShortID) {
		return fmt.Errorf("reality_short_id must be up to 16 hex characters")
	}
	if !reB64Key.MatchString(n.RealityPrivateKey) || !reB64Key.MatchString(n.RealityPublicKey) {
		return fmt.Errorf("reality keys must be base64")
	}
	return nil
}
