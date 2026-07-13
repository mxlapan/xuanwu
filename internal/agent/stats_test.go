package agent

import (
	"testing"

	statscmd "github.com/xtls/xray-core/app/stats/command"
)

func TestStatsToItems(t *testing.T) {
	stats := []*statscmd.Stat{
		{Name: "user>>>alice>>>traffic>>>uplink", Value: 100},
		{Name: "user>>>alice>>>traffic>>>downlink", Value: 900},
		{Name: "user>>>bob>>>traffic>>>downlink", Value: 50},
		{Name: "user>>>carol>>>traffic>>>uplink", Value: 0},  // zero is dropped
		{Name: "inbound>>>api>>>traffic>>>uplink", Value: 7}, // not a user stat
		{Name: "malformed", Value: 5},
	}
	got := statsToItems(stats)

	byEmail := map[string][2]int64{}
	for _, it := range got {
		byEmail[it.Email] = [2]int64{it.Up, it.Down}
	}
	if v := byEmail["alice"]; v != [2]int64{100, 900} {
		t.Errorf("alice = %v, want [100 900]", v)
	}
	if v := byEmail["bob"]; v != [2]int64{0, 50} {
		t.Errorf("bob = %v, want [0 50]", v)
	}
	if _, ok := byEmail["carol"]; ok {
		t.Error("carol (all-zero) should be omitted")
	}
	if len(got) != 2 {
		t.Errorf("got %d users, want 2 (alice, bob): %+v", len(got), got)
	}
}
