package agent

import (
	"path/filepath"
	"testing"

	"xuanwu/internal/wire"
)

func TestPendingBufferAckGatingAndPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "p.json")
	p := loadPending(path)

	p.collect([]wire.TrafficItem{{Email: "a", Up: 10, Down: 20}})
	seq, items, ok := p.batch()
	if !ok || seq != 1 || len(items) != 1 {
		t.Fatalf("first batch: seq=%d items=%v ok=%v", seq, items, ok)
	}

	// Not acked yet: a resend returns the same seq.
	if seq2, _, _ := p.batch(); seq2 != 1 {
		t.Fatalf("resend seq=%d want 1", seq2)
	}

	// New data collected while in flight stays out of the current batch.
	p.collect([]wire.TrafficItem{{Email: "a", Up: 5}})
	if seq3, _, _ := p.batch(); seq3 != 1 {
		t.Fatalf("in-flight seq changed to %d", seq3)
	}

	// Ack the batch: the next batch is a new seq with the buffered data.
	p.ack(1)
	seq4, items4, ok := p.batch()
	if !ok || seq4 != 2 || len(items4) != 1 || items4[0].Up != 5 {
		t.Fatalf("post-ack batch: seq=%d items=%v ok=%v", seq4, items4, ok)
	}
	p.ack(2)

	// Nothing left to send.
	if _, _, ok := p.batch(); ok {
		t.Fatal("expected empty batch after everything acked")
	}

	// Persistence: reloading from disk keeps the monotonic seq.
	p2 := loadPending(path)
	if p2.Seq != 2 {
		t.Fatalf("reloaded seq=%d want 2", p2.Seq)
	}
}

func TestPendingSurvivesUnacked(t *testing.T) {
	path := filepath.Join(t.TempDir(), "p.json")
	p := loadPending(path)
	p.collect([]wire.TrafficItem{{Email: "x", Up: 7, Down: 3}})
	p.batch() // in flight, never acked

	// Simulate a process restart: reload and the batch is still resendable.
	p2 := loadPending(path)
	seq, items, ok := p2.batch()
	if !ok || seq != 1 || len(items) != 1 || items[0].Up != 7 || items[0].Down != 3 {
		t.Fatalf("reloaded unacked batch: seq=%d items=%v ok=%v", seq, items, ok)
	}
}
