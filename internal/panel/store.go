package panel

import (
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// Store wraps the SQLite database. A single process-wide write mutex keeps the
// (default) SQLite file happy under concurrent HTTP + websocket goroutines.
type Store struct {
	db *sql.DB
	mu sync.Mutex
}

const schema = `
CREATE TABLE IF NOT EXISTS admins (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	username TEXT UNIQUE NOT NULL,
	password_hash TEXT NOT NULL,
	totp_secret TEXT NOT NULL DEFAULT '',
	totp_enabled INTEGER NOT NULL DEFAULT 0,
	session_epoch INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS nodes (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name TEXT NOT NULL,
	token TEXT UNIQUE NOT NULL,
	address TEXT NOT NULL DEFAULT '',
	remark TEXT NOT NULL DEFAULT '',
	last_seen INTEGER NOT NULL DEFAULT 0,
	created_at INTEGER NOT NULL DEFAULT 0,
	reality_dest TEXT NOT NULL DEFAULT '',
	reality_server_name TEXT NOT NULL DEFAULT '',
	reality_private_key TEXT NOT NULL DEFAULT '',
	reality_public_key TEXT NOT NULL DEFAULT '',
	reality_short_id TEXT NOT NULL DEFAULT '',
	tls_domain TEXT NOT NULL DEFAULT '',
	traffic_seq INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS users (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	username TEXT UNIQUE NOT NULL,
	uuid TEXT NOT NULL,
	sub_token TEXT UNIQUE NOT NULL,
	data_limit INTEGER NOT NULL DEFAULT 0,
	data_used INTEGER NOT NULL DEFAULT 0,
	expire_at INTEGER NOT NULL DEFAULT 0,
	enabled INTEGER NOT NULL DEFAULT 1,
	created_at INTEGER NOT NULL DEFAULT 0,
	portal_password_hash TEXT NOT NULL DEFAULT '',
	reset_day INTEGER NOT NULL DEFAULT 0,
	last_reset INTEGER NOT NULL DEFAULT 0,
	session_epoch INTEGER NOT NULL DEFAULT 0,
	must_change_pw INTEGER NOT NULL DEFAULT 0,
	note TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS user_nodes (
	user_id INTEGER NOT NULL,
	node_id INTEGER NOT NULL,
	PRIMARY KEY (user_id, node_id)
);
CREATE TABLE IF NOT EXISTS node_traffic (
	user_id INTEGER NOT NULL,
	node_id INTEGER NOT NULL,
	up INTEGER NOT NULL DEFAULT 0,
	down INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (user_id, node_id)
);
CREATE TABLE IF NOT EXISTS traffic_daily (
	user_id INTEGER NOT NULL,
	day TEXT NOT NULL,               -- YYYY-MM-DD (UTC)
	up INTEGER NOT NULL DEFAULT 0,
	down INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (user_id, day)
);
CREATE TABLE IF NOT EXISTS audit_log (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	ts INTEGER NOT NULL,
	actor TEXT NOT NULL,
	action TEXT NOT NULL,
	detail TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS settings (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS user_devices (
	user_id INTEGER NOT NULL,
	node_id INTEGER NOT NULL,
	ip TEXT NOT NULL,
	inbound TEXT NOT NULL DEFAULT '',
	conns INTEGER NOT NULL DEFAULT 0,
	first_seen INTEGER NOT NULL DEFAULT 0,
	last_seen INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (user_id, node_id, ip)
);
`

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // serialize; simplest correct choice for SQLite
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("init schema: %w", err)
	}
	migrate(db)
	return &Store{db: db}, nil
}

// migrate applies idempotent, additive schema changes to databases created by an
// earlier version. ADD COLUMN errors (column already exists) are expected and
// ignored, so this is safe to run on every boot.
func migrate(db *sql.DB) {
	_, _ = db.Exec(`ALTER TABLE users ADD COLUMN portal_password_hash TEXT NOT NULL DEFAULT ''`)
	_, _ = db.Exec(`ALTER TABLE users ADD COLUMN reset_day INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE users ADD COLUMN last_reset INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE nodes ADD COLUMN traffic_seq INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE admins ADD COLUMN totp_secret TEXT NOT NULL DEFAULT ''`)
	_, _ = db.Exec(`ALTER TABLE admins ADD COLUMN totp_enabled INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE admins ADD COLUMN session_epoch INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE users ADD COLUMN session_epoch INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE users ADD COLUMN must_change_pw INTEGER NOT NULL DEFAULT 0`)
	_, _ = db.Exec(`ALTER TABLE users ADD COLUMN note TEXT NOT NULL DEFAULT ''`)
}

// NodeTrafficSeq returns the last traffic batch sequence applied for a node.
func (s *Store) NodeTrafficSeq(nodeID int64) (int64, error) {
	var seq int64
	err := s.db.QueryRow(`SELECT traffic_seq FROM nodes WHERE id=?`, nodeID).Scan(&seq)
	return seq, err
}

// SetNodeTrafficSeq records the last applied traffic batch sequence for a node.
func (s *Store) SetNodeTrafficSeq(nodeID, seq int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE nodes SET traffic_seq=? WHERE id=?`, seq, nodeID)
	return err
}

func (s *Store) Close() error { return s.db.Close() }

// GetSetting returns a settings value and whether the key exists.
func (s *Store) GetSetting(key string) (string, bool, error) {
	var v string
	err := s.db.QueryRow(`SELECT value FROM settings WHERE key=?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

// SetSetting upserts a settings value.
func (s *Store) SetSetting(key, value string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=?`, key, value, value)
	return err
}

// BackupTo writes a consistent snapshot of the database to path (which must not
// already exist), using SQLite's VACUUM INTO.
func (s *Store) BackupTo(path string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`VACUUM INTO ?`, path)
	return err
}

// ---- admins ----

func (s *Store) EnsureAdmin(username, passwordHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var id int64
	err := s.db.QueryRow(`SELECT id FROM admins WHERE username=?`, username).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		_, err = s.db.Exec(`INSERT INTO admins(username,password_hash) VALUES(?,?)`, username, passwordHash)
		return err
	}
	if err != nil {
		return err
	}
	// keep password in sync with env on boot
	_, err = s.db.Exec(`UPDATE admins SET password_hash=? WHERE id=?`, passwordHash, id)
	return err
}

func (s *Store) GetAdmin(username string) (*Admin, error) {
	a := &Admin{}
	var enabled int
	err := s.db.QueryRow(`SELECT id,username,password_hash,totp_secret,totp_enabled,session_epoch FROM admins WHERE username=?`, username).
		Scan(&a.ID, &a.Username, &a.PasswordHash, &a.TOTPSecret, &enabled, &a.SessionEpoch)
	if err != nil {
		return nil, err
	}
	a.TOTPEnabled = enabled != 0
	return a, nil
}

// BumpAdminSessionEpoch invalidates every existing admin session.
func (s *Store) BumpAdminSessionEpoch(username string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE admins SET session_epoch=session_epoch+1 WHERE username=?`, username)
	return err
}

// BumpUserSessionEpoch invalidates every existing portal session for a user.
func (s *Store) BumpUserSessionEpoch(userID int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE users SET session_epoch=session_epoch+1 WHERE id=?`, userID)
	return err
}

// SetAdminTOTP stores an admin's TOTP secret and enabled flag.
func (s *Store) SetAdminTOTP(username, secret string, enabled bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	e := 0
	if enabled {
		e = 1
	}
	_, err := s.db.Exec(`UPDATE admins SET totp_secret=?,totp_enabled=? WHERE username=?`, secret, e, username)
	return err
}

// ListAdmins returns all admin usernames.
func (s *Store) ListAdmins() ([]string, error) {
	rows, err := s.db.Query(`SELECT username FROM admins ORDER BY username`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Store) CountAdmins() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM admins`).Scan(&n)
	return n, err
}

func (s *Store) CreateAdmin(username, hash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`INSERT INTO admins(username,password_hash) VALUES(?,?)`, username, hash)
	return err
}

func (s *Store) DeleteAdmin(username string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`DELETE FROM admins WHERE username=?`, username)
	return err
}

// SetAdminPassword changes an admin's password and bumps its session epoch so
// existing sessions for that admin are revoked.
func (s *Store) SetAdminPassword(username, hash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE admins SET password_hash=?,session_epoch=session_epoch+1 WHERE username=?`, hash, username)
	return err
}

// ---- devices ----

// Device is one observed client device (source IP) for a user.
type Device struct {
	IP        string `json:"ip"`
	Inbound   string `json:"inbound"`
	Conns     int64  `json:"conns"`
	NodeID    int64  `json:"node_id"`
	FirstSeen int64  `json:"first_seen"`
	LastSeen  int64  `json:"last_seen"`
}

// UpsertDevice records/updates a user's device observation on a node.
func (s *Store) UpsertDevice(userID, nodeID int64, ip, inbound string, conns, seen int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`INSERT INTO user_devices(user_id,node_id,ip,inbound,conns,first_seen,last_seen)
		VALUES(?,?,?,?,?,?,?)
		ON CONFLICT(user_id,node_id,ip) DO UPDATE SET conns=conns+?,inbound=?,last_seen=?`,
		userID, nodeID, ip, inbound, conns, seen, seen, conns, inbound, seen)
	return err
}

// ListUserDevices returns a user's devices, most-recent first.
func (s *Store) ListUserDevices(userID int64) ([]Device, error) {
	rows, err := s.db.Query(`SELECT ip,inbound,conns,node_id,first_seen,last_seen
		FROM user_devices WHERE user_id=? ORDER BY last_seen DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.IP, &d.Inbound, &d.Conns, &d.NodeID, &d.FirstSeen, &d.LastSeen); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// DeviceCounts returns distinct-IP device counts per user seen since `since`.
func (s *Store) DeviceCounts(since int64) (map[int64]int, error) {
	rows, err := s.db.Query(`SELECT user_id, COUNT(DISTINCT ip) FROM user_devices WHERE last_seen>=? GROUP BY user_id`, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]int{}
	for rows.Next() {
		var uid int64
		var n int
		if err := rows.Scan(&uid, &n); err != nil {
			return nil, err
		}
		out[uid] = n
	}
	return out, rows.Err()
}

// ---- audit ----

// AuditEntry is one recorded admin action.
type AuditEntry struct {
	ID     int64  `json:"id"`
	TS     int64  `json:"ts"`
	Actor  string `json:"actor"`
	Action string `json:"action"`
	Detail string `json:"detail"`
}

func (s *Store) AddAudit(actor, action, detail string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`INSERT INTO audit_log(ts,actor,action,detail) VALUES(?,?,?,?)`,
		time.Now().Unix(), actor, action, detail)
	return err
}

func (s *Store) ListAudit(limit int) ([]AuditEntry, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := s.db.Query(`SELECT id,ts,actor,action,detail FROM audit_log ORDER BY id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]AuditEntry, 0, limit)
	for rows.Next() {
		var e AuditEntry
		if err := rows.Scan(&e.ID, &e.TS, &e.Actor, &e.Action, &e.Detail); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// ---- nodes ----

func scanNode(sc interface{ Scan(...any) error }) (*Node, error) {
	n := &Node{}
	err := sc.Scan(&n.ID, &n.Name, &n.Token, &n.Address, &n.Remark, &n.LastSeen, &n.CreatedAt,
		&n.RealityDest, &n.RealityServerName, &n.RealityPrivateKey, &n.RealityPublicKey,
		&n.RealityShortID, &n.TLSDomain)
	if err != nil {
		return nil, err
	}
	n.Online = time.Now().Unix()-n.LastSeen < 60
	return n, nil
}

const nodeCols = `id,name,token,address,remark,last_seen,created_at,reality_dest,reality_server_name,reality_private_key,reality_public_key,reality_short_id,tls_domain`

func (s *Store) ListNodes() ([]*Node, error) {
	rows, err := s.db.Query(`SELECT ` + nodeCols + ` FROM nodes ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Node
	for rows.Next() {
		n, err := scanNode(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

func (s *Store) GetNode(id int64) (*Node, error) {
	return scanNode(s.db.QueryRow(`SELECT `+nodeCols+` FROM nodes WHERE id=?`, id))
}

func (s *Store) GetNodeByToken(token string) (*Node, error) {
	return scanNode(s.db.QueryRow(`SELECT `+nodeCols+` FROM nodes WHERE token=?`, token))
}

func (s *Store) CreateNode(n *Node) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, err := s.db.Exec(`INSERT INTO nodes(name,token,address,remark,created_at,reality_dest,reality_server_name,reality_private_key,reality_public_key,reality_short_id,tls_domain)
		VALUES(?,?,?,?,?,?,?,?,?,?,?)`,
		n.Name, n.Token, n.Address, n.Remark, time.Now().Unix(),
		n.RealityDest, n.RealityServerName, n.RealityPrivateKey, n.RealityPublicKey, n.RealityShortID, n.TLSDomain)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) UpdateNode(n *Node) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE nodes SET name=?,address=?,remark=?,reality_dest=?,reality_server_name=?,reality_private_key=?,reality_public_key=?,reality_short_id=?,tls_domain=? WHERE id=?`,
		n.Name, n.Address, n.Remark, n.RealityDest, n.RealityServerName, n.RealityPrivateKey, n.RealityPublicKey, n.RealityShortID, n.TLSDomain, n.ID)
	return err
}

func (s *Store) DeleteNode(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM user_nodes WHERE node_id=?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM node_traffic WHERE node_id=?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM nodes WHERE id=?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) TouchNode(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE nodes SET last_seen=? WHERE id=?`, time.Now().Unix(), id)
	return err
}

// ---- users ----

func scanUser(sc interface{ Scan(...any) error }) (*User, error) {
	u := &User{}
	var enabled int
	var mustChange int
	err := sc.Scan(&u.ID, &u.Username, &u.UUID, &u.SubToken, &u.DataLimit, &u.DataUsed, &u.ExpireAt, &enabled, &u.CreatedAt, &u.PortalPasswordHash, &u.ResetDay, &u.LastReset, &u.SessionEpoch, &mustChange, &u.Note)
	if err != nil {
		return nil, err
	}
	u.Enabled = enabled != 0
	u.HasPortalPassword = u.PortalPasswordHash != ""
	u.MustChangePW = mustChange != 0
	return u, nil
}

const userCols = `id,username,uuid,sub_token,data_limit,data_used,expire_at,enabled,created_at,portal_password_hash,reset_day,last_reset,session_epoch,must_change_pw,note`

func (s *Store) ListUsers() ([]*User, error) {
	rows, err := s.db.Query(`SELECT ` + userCols + ` FROM users ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// attach node assignments
	for _, u := range out {
		ids, err := s.userNodeIDs(u.ID)
		if err != nil {
			return nil, err
		}
		u.NodeIDs = ids
	}
	return out, nil
}

func (s *Store) GetUser(id int64) (*User, error) {
	u, err := scanUser(s.db.QueryRow(`SELECT `+userCols+` FROM users WHERE id=?`, id))
	if err != nil {
		return nil, err
	}
	u.NodeIDs, err = s.userNodeIDs(id)
	return u, err
}

func (s *Store) GetUserBySubToken(token string) (*User, error) {
	u, err := scanUser(s.db.QueryRow(`SELECT `+userCols+` FROM users WHERE sub_token=?`, token))
	if err != nil {
		return nil, err
	}
	u.NodeIDs, err = s.userNodeIDs(u.ID)
	return u, err
}

func (s *Store) GetUserByName(name string) (*User, error) {
	return scanUser(s.db.QueryRow(`SELECT `+userCols+` FROM users WHERE username=?`, name))
}

func (s *Store) userNodeIDs(userID int64) ([]int64, error) {
	rows, err := s.db.Query(`SELECT node_id FROM user_nodes WHERE user_id=? ORDER BY node_id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

func (s *Store) CreateUser(u *User) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	enabled := 0
	if u.Enabled {
		enabled = 1
	}
	res, err := s.db.Exec(`INSERT INTO users(username,uuid,sub_token,data_limit,expire_at,enabled,created_at,reset_day,note)
		VALUES(?,?,?,?,?,?,?,?,?)`,
		u.Username, u.UUID, u.SubToken, u.DataLimit, u.ExpireAt, enabled, time.Now().Unix(), u.ResetDay, u.Note)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) UpdateUser(u *User) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	enabled := 0
	if u.Enabled {
		enabled = 1
	}
	_, err := s.db.Exec(`UPDATE users SET data_limit=?,expire_at=?,enabled=?,reset_day=?,note=? WHERE id=?`,
		u.DataLimit, u.ExpireAt, enabled, u.ResetDay, u.Note, u.ID)
	return err
}

// SetUserSubToken replaces a user's subscription token (rotation on leak).
func (s *Store) SetUserSubToken(userID int64, token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE users SET sub_token=? WHERE id=?`, token, userID)
	return err
}

// SetUserUUID replaces a user's VLESS UUID (rotation on leak); requires a config
// re-push to every assigned node.
func (s *Store) SetUserUUID(userID int64, uuid string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE users SET uuid=? WHERE id=?`, uuid, userID)
	return err
}

// SetUserLastReset records when a user's monthly counter was last auto-reset.
func (s *Store) SetUserLastReset(userID, ts int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE users SET last_reset=? WHERE id=?`, ts, userID)
	return err
}

// DailyTraffic is one day's aggregate usage for a user.
type DailyTraffic struct {
	Day  string `json:"day"`
	Up   int64  `json:"up"`
	Down int64  `json:"down"`
}

// TrafficHistory returns the last `days` days of daily usage for a user, oldest
// first, including zero-fill for days with no traffic.
func (s *Store) TrafficHistory(userID int64, days int) ([]DailyTraffic, error) {
	if days < 1 {
		days = 30
	}
	rows, err := s.db.Query(`SELECT day,up,down FROM traffic_daily WHERE user_id=? AND day>=? ORDER BY day`,
		userID, time.Now().UTC().AddDate(0, 0, -days+1).Format("2006-01-02"))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	byDay := map[string]DailyTraffic{}
	for rows.Next() {
		var d DailyTraffic
		if err := rows.Scan(&d.Day, &d.Up, &d.Down); err != nil {
			return nil, err
		}
		byDay[d.Day] = d
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out := make([]DailyTraffic, 0, days)
	for i := days - 1; i >= 0; i-- {
		day := time.Now().UTC().AddDate(0, 0, -i).Format("2006-01-02")
		if d, ok := byDay[day]; ok {
			out = append(out, d)
		} else {
			out = append(out, DailyTraffic{Day: day})
		}
	}
	return out, nil
}

func (s *Store) DeleteUser(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM user_nodes WHERE user_id=?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM node_traffic WHERE user_id=?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM users WHERE id=?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// SetUserNodes replaces a user's node assignments.
func (s *Store) SetUserNodes(userID int64, nodeIDs []int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM user_nodes WHERE user_id=?`, userID); err != nil {
		return err
	}
	for _, nid := range nodeIDs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO user_nodes(user_id,node_id) VALUES(?,?)`, userID, nid); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// UsersForNode returns all users assigned to a node.
func (s *Store) UsersForNode(nodeID int64) ([]*User, error) {
	rows, err := s.db.Query(`SELECT `+userCols+` FROM users u
		JOIN user_nodes un ON un.user_id=u.id WHERE un.node_id=? ORDER BY u.id`, nodeID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// AddTraffic increments a user's aggregate usage and the per-node breakdown.
func (s *Store) AddTraffic(userID, nodeID, up, down int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().Unix()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE users SET data_used=data_used+? WHERE id=?`, up+down, userID); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO node_traffic(user_id,node_id,up,down,updated_at) VALUES(?,?,?,?,?)
		ON CONFLICT(user_id,node_id) DO UPDATE SET up=up+?,down=down+?,updated_at=?`,
		userID, nodeID, up, down, now, up, down, now); err != nil {
		return err
	}
	day := time.Unix(now, 0).UTC().Format("2006-01-02")
	if _, err := tx.Exec(`INSERT INTO traffic_daily(user_id,day,up,down) VALUES(?,?,?,?)
		ON CONFLICT(user_id,day) DO UPDATE SET up=up+?,down=down+?`,
		userID, day, up, down, up, down); err != nil {
		return err
	}
	return tx.Commit()
}

// SetUserPortalPassword stores (or clears, when hash is "") a user's self-service
// portal password hash. mustChange marks the password as temporary so the portal
// forces the user to change it on next login.
func (s *Store) SetUserPortalPassword(userID int64, hash string, mustChange bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	mc := 0
	if mustChange {
		mc = 1
	}
	_, err := s.db.Exec(`UPDATE users SET portal_password_hash=?,must_change_pw=? WHERE id=?`, hash, mc, userID)
	return err
}

// ChangeUserPortalPassword sets a user's own new password, clears the
// must-change flag, and bumps the session epoch (revoking other sessions).
func (s *Store) ChangeUserPortalPassword(userID int64, hash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE users SET portal_password_hash=?,must_change_pw=0,session_epoch=session_epoch+1 WHERE id=?`, hash, userID)
	return err
}

// ResetUserTraffic zeroes a user's aggregate usage (e.g. monthly reset).
func (s *Store) ResetUserTraffic(userID int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE users SET data_used=0 WHERE id=?`, userID)
	return err
}
