package agent

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// localUser is a standalone-mode account persisted to a local JSON file.
type localUser struct {
	Name string `json:"name"`
	UUID string `json:"uuid"`
}

type localDB struct {
	Users []localUser `json:"users"`
}

func loadLocalDB(path string) (*localDB, error) {
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return &localDB{}, nil
	}
	if err != nil {
		return nil, err
	}
	db := &localDB{}
	if len(b) > 0 {
		if err := json.Unmarshal(b, db); err != nil {
			return nil, err
		}
	}
	return db, nil
}

func saveLocalDB(path string, db *localDB) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(db, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

func (db *localDB) find(name string) int {
	for i, u := range db.Users {
		if u.Name == name {
			return i
		}
	}
	return -1
}

// genUUID returns a random RFC-4122 v4 UUID. A failing CSPRNG is unrecoverable,
// so we panic rather than emit a predictable UUID.
func genUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
