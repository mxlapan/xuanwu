package panel

import (
	"context"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// handleBackup streams a consistent snapshot of the database. It uses SQLite's
// VACUUM INTO so the copy is transactionally consistent even under WAL and
// concurrent writes.
func (a *App) handleBackup(w http.ResponseWriter, r *http.Request) {
	tmp, err := os.CreateTemp("", "xuanwu-backup-*.db")
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	tmpPath := tmp.Name()
	tmp.Close()
	_ = os.Remove(tmpPath) // VACUUM INTO requires the target not to exist yet
	defer os.Remove(tmpPath)

	if err := a.store.BackupTo(tmpPath); err != nil {
		writeErr(w, 500, "backup failed: "+err.Error())
		return
	}
	f, err := os.Open(tmpPath)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	defer f.Close()

	name := "panel-" + time.Now().Format("20060102-150405") + ".db"
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	_, _ = io.Copy(w, f)
}

// backupLoop writes a daily on-disk snapshot to dir, retaining the newest
// `backup_keep` files (read live from settings each run). It runs one backup at
// boot and then daily. dir=="" disables it.
func (a *App) backupLoop(ctx context.Context, dir string) {
	if dir == "" {
		return
	}
	// 0o755 so the host user can read snapshots from the bind-mounted dir
	// (e.g. `./deploy.sh backup`). The DB itself already lives in the same dir.
	if err := os.MkdirAll(dir, 0o755); err != nil {
		log.Printf("backup: mkdir %s: %v", dir, err)
		return
	}
	do := func() {
		keep := a.backupKeep()
		if keep <= 0 {
			return // backups disabled via settings
		}
		name := filepath.Join(dir, "panel-"+time.Now().Format("20060102")+".db")
		_ = os.Remove(name) // overwrite today's snapshot
		if err := a.store.BackupTo(name); err != nil {
			log.Printf("backup: %v", err)
			return
		}
		_ = os.Chmod(name, 0o644)
		entries, _ := filepath.Glob(filepath.Join(dir, "panel-*.db"))
		sort.Strings(entries) // names sort chronologically (panel-YYYYMMDD.db)
		if len(entries) > keep {
			for _, old := range entries[:len(entries)-keep] {
				_ = os.Remove(old)
			}
		}
		log.Printf("backup: wrote %s (keeping %d)", name, keep)
	}
	do()
	t := time.NewTicker(24 * time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			do()
		}
	}
}
