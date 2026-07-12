package panel

import (
	"os"
	"path/filepath"
	"testing"

	"xuanwu/internal/wire"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestPortalPasswordFlag(t *testing.T) {
	s := newTestStore(t)
	id, err := s.CreateUser(&User{Username: "a", UUID: "u", SubToken: "tok", Enabled: true})
	if err != nil {
		t.Fatal(err)
	}
	u, _ := s.GetUser(id)
	if u.HasPortalPassword {
		t.Fatal("new user should not have a portal password")
	}
	if err := s.SetUserPortalPassword(id, "somehash", false); err != nil {
		t.Fatal(err)
	}
	u, _ = s.GetUser(id)
	if !u.HasPortalPassword || u.PortalPasswordHash != "somehash" {
		t.Fatalf("portal password not stored: %+v", u)
	}
}

func TestMustChangePasswordFlow(t *testing.T) {
	s := newTestStore(t)
	id, _ := s.CreateUser(&User{Username: "a", UUID: "u", SubToken: "tok", Enabled: true})
	// Admin sets a temporary password.
	if err := s.SetUserPortalPassword(id, "hash1", true); err != nil {
		t.Fatal(err)
	}
	u, _ := s.GetUser(id)
	if !u.MustChangePW || !u.HasPortalPassword {
		t.Fatalf("expected must-change + has-password, got %+v", u)
	}
	epoch0 := u.SessionEpoch
	// User changes it themselves.
	if err := s.ChangeUserPortalPassword(id, "hash2"); err != nil {
		t.Fatal(err)
	}
	u, _ = s.GetUser(id)
	if u.MustChangePW {
		t.Fatal("must-change flag should be cleared")
	}
	if u.PortalPasswordHash != "hash2" {
		t.Fatalf("password not updated: %q", u.PortalPasswordHash)
	}
	if u.SessionEpoch != epoch0+1 {
		t.Fatalf("session epoch not bumped: %d -> %d", epoch0, u.SessionEpoch)
	}
}

func TestUserDevices(t *testing.T) {
	s := newTestStore(t)
	uid, _ := s.CreateUser(&User{Username: "a", UUID: "u", SubToken: "tok", Enabled: true})
	nid, _ := s.CreateNode(&Node{Name: "n", Token: "nt"})
	now := int64(1_800_000_000)
	// Same IP twice -> conns accumulate; two distinct IPs -> count 2.
	s.UpsertDevice(uid, nid, "1.2.3.4", "reality", 1, now)
	s.UpsertDevice(uid, nid, "1.2.3.4", "reality", 2, now+10)
	s.UpsertDevice(uid, nid, "5.6.7.8", "tls", 1, now+20)

	devs, err := s.ListUserDevices(uid)
	if err != nil || len(devs) != 2 {
		t.Fatalf("devices = %v (err %v), want 2", devs, err)
	}
	// Most recent first.
	if devs[0].IP != "5.6.7.8" {
		t.Fatalf("expected newest first, got %s", devs[0].IP)
	}
	var conns14 int64
	for _, d := range devs {
		if d.IP == "1.2.3.4" {
			conns14 = d.Conns
		}
	}
	if conns14 != 3 {
		t.Fatalf("1.2.3.4 conns = %d, want 3", conns14)
	}
	counts, err := s.DeviceCounts(now)
	if err != nil || counts[uid] != 2 {
		t.Fatalf("device count = %v (err %v), want 2", counts[uid], err)
	}
	// Cutoff after all activity -> 0.
	if c, _ := s.DeviceCounts(now + 1000); c[uid] != 0 {
		t.Fatalf("device count with future cutoff = %d, want 0", c[uid])
	}
}

func TestMigrationIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "t.db")
	s1, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	s1.Close()
	// Re-opening (migrate runs again) must not error.
	s2, err := OpenStore(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	s2.Close()
}

func TestBackupTo(t *testing.T) {
	s := newTestStore(t)
	s.CreateUser(&User{Username: "a", UUID: "u", SubToken: "s", Enabled: true})
	bpath := filepath.Join(t.TempDir(), "b.db")
	if err := s.BackupTo(bpath); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(bpath)
	if err != nil || fi.Size() == 0 {
		t.Fatalf("backup missing or empty: %v", err)
	}
}

func TestIngestTrafficScopingAndDedup(t *testing.T) {
	s := newTestStore(t)
	app := &App{store: s, activeCache: map[int64]string{}}
	app.hub = NewHub(app)

	nid, _ := s.CreateNode(&Node{Name: "n", Token: "nt"})
	uid, _ := s.CreateUser(&User{Username: "assigned", UUID: "u1", SubToken: "s1", Enabled: true})
	if err := s.SetUserNodes(uid, []int64{nid}); err != nil {
		t.Fatal(err)
	}
	other, _ := s.CreateUser(&User{Username: "other", UUID: "u2", SubToken: "s2", Enabled: true}) // not assigned

	// Batch seq 1: reports for an assigned and an unassigned user.
	app.ingestTraffic(nid, 1, []wire.TrafficItem{
		{Email: "assigned", Up: 100, Down: 200},
		{Email: "other", Up: 999, Down: 999},
	})
	if ua, _ := s.GetUser(uid); ua.DataUsed != 300 {
		t.Fatalf("assigned used=%d want 300", ua.DataUsed)
	}
	if uo, _ := s.GetUser(other); uo.DataUsed != 0 {
		t.Fatalf("unassigned user got traffic: used=%d want 0", uo.DataUsed)
	}

	// Duplicate seq 1 must be ignored.
	app.ingestTraffic(nid, 1, []wire.TrafficItem{{Email: "assigned", Up: 100, Down: 200}})
	if ua, _ := s.GetUser(uid); ua.DataUsed != 300 {
		t.Fatalf("duplicate batch applied: used=%d want 300", ua.DataUsed)
	}

	// New seq 2 applies.
	app.ingestTraffic(nid, 2, []wire.TrafficItem{{Email: "assigned", Up: 0, Down: 50}})
	if ua, _ := s.GetUser(uid); ua.DataUsed != 350 {
		t.Fatalf("seq 2 not applied: used=%d want 350", ua.DataUsed)
	}
}
