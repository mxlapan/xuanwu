package panel

import "testing"

func TestCrypterRoundTrip(t *testing.T) {
	c := newCrypter("a-stable-secret-at-least-16-chars")
	for _, pt := range []string{"hunter2", "reality-private-key", "", "utf8-✓-secret"} {
		enc := c.encrypt(pt)
		if pt != "" && !isEncrypted(enc) {
			t.Fatalf("encrypt(%q) not marked: %q", pt, enc)
		}
		if got := c.decrypt(enc); got != pt {
			t.Fatalf("round-trip %q -> %q -> %q", pt, enc, got)
		}
	}
	// Empty stays empty (so unset secrets remain queryable as "").
	if c.encrypt("") != "" {
		t.Fatal("encrypt(\"\") must stay empty")
	}
	// Re-encryption is idempotent.
	enc := c.encrypt("x")
	if c.encrypt(enc) != enc {
		t.Fatal("encrypt must be idempotent on ciphertext")
	}
}

func TestCrypterNilPassthrough(t *testing.T) {
	var c *crypter // encryption disabled (tests / no secret)
	if c.encrypt("secret") != "secret" || c.decrypt("secret") != "secret" {
		t.Fatal("nil crypter must pass through plaintext")
	}
}

func TestCrypterLegacyPlaintext(t *testing.T) {
	c := newCrypter("a-stable-secret-at-least-16-chars")
	// A value written before encryption existed carries no marker and must read
	// back verbatim.
	if got := c.decrypt("legacy-plaintext"); got != "legacy-plaintext" {
		t.Fatalf("legacy plaintext mangled: %q", got)
	}
}

func TestCrypterWrongKeyFailsClosed(t *testing.T) {
	enc := newCrypter("first-secret-16chars-long!!").encrypt("topsecret")
	if got := newCrypter("second-secret-16chars-long!").decrypt(enc); got != "" {
		t.Fatalf("wrong key must not decrypt; got %q", got)
	}
}

func TestEncryptExistingMigratesLegacyRows(t *testing.T) {
	s := newTestStore(t)
	// Simulate a legacy DB: plaintext secrets written with no crypter.
	nid, _ := s.CreateNode(&Node{Name: "n", Token: "nt", RealityPrivateKey: "raw-priv"})
	_, _ = s.db.Exec(`INSERT INTO admins(username,password_hash,totp_secret,totp_enabled) VALUES('root','h','RAWTOTP',1)`)
	_ = s.SetSetting("telegram_token", "raw-bot-token")

	// Enable encryption and migrate.
	s.crypt = newCrypter("a-stable-secret-at-least-16-chars")
	if err := s.encryptExisting(); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	// Stored bytes are now ciphertext...
	var rawPriv, rawTotp, rawTok string
	_ = s.db.QueryRow(`SELECT reality_private_key FROM nodes WHERE id=?`, nid).Scan(&rawPriv)
	_ = s.db.QueryRow(`SELECT totp_secret FROM admins WHERE username='root'`).Scan(&rawTotp)
	_ = s.db.QueryRow(`SELECT value FROM settings WHERE key='telegram_token'`).Scan(&rawTok)
	for name, v := range map[string]string{"priv": rawPriv, "totp": rawTotp, "token": rawTok} {
		if !isEncrypted(v) {
			t.Fatalf("%s not encrypted at rest: %q", name, v)
		}
	}

	// ...but reads transparently return plaintext.
	n, _ := s.GetNode(nid)
	if n.RealityPrivateKey != "raw-priv" {
		t.Fatalf("priv decrypt = %q", n.RealityPrivateKey)
	}
	adm, _ := s.GetAdmin("root")
	if adm.TOTPSecret != "RAWTOTP" {
		t.Fatalf("totp decrypt = %q", adm.TOTPSecret)
	}
	if v, _, _ := s.GetSecretSetting("telegram_token"); v != "raw-bot-token" {
		t.Fatalf("token decrypt = %q", v)
	}

	// Idempotent: a second run changes nothing.
	if err := s.encryptExisting(); err != nil {
		t.Fatalf("migrate again: %v", err)
	}
	if n2, _ := s.GetNode(nid); n2.RealityPrivateKey != "raw-priv" {
		t.Fatalf("second migrate corrupted priv: %q", n2.RealityPrivateKey)
	}
}
