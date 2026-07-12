package panel

import (
	"testing"
	"time"
)

func TestMonthlyResetDue(t *testing.T) {
	utc := time.UTC
	mk := func(y int, m time.Month, d int) time.Time { return time.Date(y, m, d, 12, 0, 0, 0, utc) }

	cases := []struct {
		name      string
		now       time.Time
		resetDay  int64
		lastReset int64
		wantDue   bool
	}{
		{"disabled", mk(2026, 3, 15), 0, 0, false},
		{"before reset day", mk(2026, 3, 10), 15, 0, false},
		{"on reset day, never reset", mk(2026, 3, 15), 15, 0, true},
		{"after reset day, never reset", mk(2026, 3, 20), 15, 0, true},
		{"already reset this month", mk(2026, 3, 20), 15, mk(2026, 3, 15).Unix(), false},
		{"reset was last month", mk(2026, 3, 20), 15, mk(2026, 2, 15).Unix(), true},
		{"day clamped in Feb", mk(2026, 2, 28), 28, 0, true},
	}
	for _, c := range cases {
		_, due := monthlyResetDue(c.now, c.resetDay, c.lastReset)
		if due != c.wantDue {
			t.Errorf("%s: due=%v want %v", c.name, due, c.wantDue)
		}
	}
}
