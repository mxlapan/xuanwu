package panel

import (
	"testing"
	"time"
)

func TestSessionRoundTripAndRoleIsolation(t *testing.T) {
	sec := "test-secret-0123456789abcdef"

	tok := signSession(sec, roleUser, "42", 3, time.Hour)
	role, sub, epoch, ok := verifySession(sec, tok)
	if !ok || role != roleUser || sub != "42" || epoch != 3 {
		t.Fatalf("round trip: role=%q sub=%q epoch=%d ok=%v", role, sub, epoch, ok)
	}
	// The critical property: a portal (user) token must not carry the admin role.
	if role == roleAdmin {
		t.Fatal("user token verified with admin role")
	}

	// Wrong secret must not verify.
	if _, _, _, ok := verifySession("different-secret-000000000", tok); ok {
		t.Fatal("token verified under the wrong secret")
	}
	// Tampering must not verify.
	bad := tok[:5] + "X" + tok[6:]
	if _, _, _, ok := verifySession(sec, bad); ok {
		t.Fatal("tampered token verified")
	}
	// Expired must not verify.
	exp := signSession(sec, roleAdmin, "admin", 0, -time.Second)
	if _, _, _, ok := verifySession(sec, exp); ok {
		t.Fatal("expired token verified")
	}
}

func TestValidateSecrets(t *testing.T) {
	good := "0123456789abcdef0123456789abcdef"
	cases := []struct {
		name    string
		cfg     Config
		wantErr bool
	}{
		{"weak default pass", Config{AdminPass: "admin", JWTSecret: good}, true},
		{"empty pass", Config{AdminPass: "", JWTSecret: good}, true},
		{"weak override allowed", Config{AdminPass: "admin", JWTSecret: good, AllowWeakPass: true}, false},
		{"placeholder jwt", Config{AdminPass: "Str0ng-Pass-1", JWTSecret: "replace-with-64-hex-chars"}, true},
		{"short jwt", Config{AdminPass: "Str0ng-Pass-1", JWTSecret: "short"}, true},
		{"valid", Config{AdminPass: "Str0ng-Pass-1", JWTSecret: good}, false},
		{"empty jwt ok (ephemeral)", Config{AdminPass: "Str0ng-Pass-1", JWTSecret: ""}, false},
	}
	for _, c := range cases {
		err := validateSecrets(c.cfg)
		if (err != nil) != c.wantErr {
			t.Errorf("%s: err=%v wantErr=%v", c.name, err, c.wantErr)
		}
	}
}

func TestValidatePasswordStrength(t *testing.T) {
	cases := []struct {
		pw string
		ok bool
	}{
		{"Str0ng!x", true},
		{"Test-Admin-6e980e", true},
		{"short1!", false},      // too short
		{"alllower123!", false}, // no uppercase
		{"ALLUPPER123!", false}, // no lowercase
		{"NoDigits!!", false},   // no digit
		{"NoSpecial123", false}, // no special
		{"", false},             // empty
		{"Aa1!aaaa", true},      // exactly 8 with all classes
	}
	for _, c := range cases {
		if err := validatePasswordStrength(c.pw); (err == nil) != c.ok {
			t.Errorf("validatePasswordStrength(%q): ok=%v want %v", c.pw, err == nil, c.ok)
		}
	}
}

func TestLimiter(t *testing.T) {
	l := newLimiter(3, time.Minute)
	k := "ip:1.2.3.4"
	for i := 0; i < 3; i++ {
		if l.blocked(k) {
			t.Fatalf("blocked before reaching max (i=%d)", i)
		}
		l.fail(k)
	}
	if !l.blocked(k) {
		t.Fatal("not blocked after max failures")
	}
	l.reset(k)
	if l.blocked(k) {
		t.Fatal("still blocked after reset")
	}

	// Window expiry frees the key.
	l2 := newLimiter(1, time.Millisecond)
	l2.fail(k)
	if !l2.blocked(k) {
		t.Fatal("expected block")
	}
	time.Sleep(3 * time.Millisecond)
	if l2.blocked(k) {
		t.Fatal("block should have expired")
	}
}
