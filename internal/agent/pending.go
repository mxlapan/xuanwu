package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"xuanwu/internal/wire"
)

// pendingTraffic is a durable, at-least-once buffer for traffic reports. Xray's
// stats are read-and-reset, so once collected the bytes exist only here until the
// panel acknowledges them. The buffer is persisted to disk so an agent restart or
// a dropped panel connection does not lose a reporting window.
//
// Layout: freshly collected deltas accumulate in `pend`. When there is no batch
// in flight, `pend` is promoted to `flight` under a new monotonically increasing
// `seq` and sent. The batch is resent (same seq) until the panel acks it, at
// which point `flight` is cleared and the next `pend` can be sent.
type pendingTraffic struct {
	mu   sync.Mutex
	path string

	Seq      int64            `json:"seq"`       // last assigned batch seq
	Flight   map[string]*pair `json:"flight"`    // unacked batch (empty if none)
	FlightAt bool             `json:"flight_at"` // whether a batch is in flight
	Pend     map[string]*pair `json:"pend"`      // collected, not yet batched
}

type pair struct {
	Up   int64 `json:"up"`
	Down int64 `json:"down"`
}

func loadPending(path string) *pendingTraffic {
	p := &pendingTraffic{path: path, Flight: map[string]*pair{}, Pend: map[string]*pair{}}
	b, err := os.ReadFile(path)
	if err == nil && len(b) > 0 {
		_ = json.Unmarshal(b, p)
		if p.Flight == nil {
			p.Flight = map[string]*pair{}
		}
		if p.Pend == nil {
			p.Pend = map[string]*pair{}
		}
	}
	return p
}

// save writes the buffer atomically. Caller holds the lock.
func (p *pendingTraffic) save() {
	if p.path == "" {
		return
	}
	b, err := json.Marshal(p)
	if err != nil {
		return
	}
	tmp := p.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return
	}
	_ = os.Rename(tmp, p.path)
}

func mergeInto(dst map[string]*pair, items []wire.TrafficItem) {
	for _, it := range items {
		if it.Up == 0 && it.Down == 0 {
			continue
		}
		e := dst[it.Email]
		if e == nil {
			e = &pair{}
			dst[it.Email] = e
		}
		e.Up += it.Up
		e.Down += it.Down
	}
}

// collect merges a freshly read delta into the pending set.
func (p *pendingTraffic) collect(items []wire.TrafficItem) {
	if len(items) == 0 {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	mergeInto(p.Pend, items)
	p.save()
}

// batch returns the current batch to send (seq, items). If a batch is already in
// flight it is returned again (a resend). Otherwise pending is promoted to a new
// batch. Returns ok=false when there is nothing to send.
func (p *pendingTraffic) batch() (int64, []wire.TrafficItem, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.FlightAt {
		if len(p.Pend) == 0 {
			return 0, nil, false
		}
		p.Seq++
		p.Flight = p.Pend
		p.Pend = map[string]*pair{}
		p.FlightAt = true
		p.save()
	}
	items := make([]wire.TrafficItem, 0, len(p.Flight))
	for email, v := range p.Flight {
		items = append(items, wire.TrafficItem{Email: email, Up: v.Up, Down: v.Down})
	}
	return p.Seq, items, len(items) > 0
}

// ack clears the in-flight batch once the panel confirms it.
func (p *pendingTraffic) ack(seq int64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.FlightAt && seq == p.Seq {
		p.Flight = map[string]*pair{}
		p.FlightAt = false
		p.save()
	}
}

func pendingPath(usersFile string) string {
	return filepath.Join(filepath.Dir(usersFile), "pending-traffic.json")
}
