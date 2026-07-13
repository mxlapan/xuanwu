package agent

import (
	"context"
	"log"
	"strings"
	"time"

	statscmd "github.com/xtls/xray-core/app/stats/command"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"xuanwu/internal/wire"
)

// collectTraffic reads and resets per-user counters via Xray's StatsService over
// the same private gRPC API the agent already uses for live user edits. This
// replaces the old `docker exec xray xray api statsquery` path, so the agent no
// longer needs to exec into the Xray container (and thus no longer needs broad
// Docker access — see cmd docker proxy).
func (c *Config) collectTraffic() []wire.TrafficItem {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	conn, err := grpc.NewClient(c.GRPCAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Printf("stats grpc dial %s: %v", c.GRPCAddr, err)
		return nil
	}
	defer conn.Close()

	ss := statscmd.NewStatsServiceClient(conn)
	// Pattern "user>>>" selects per-user counters; Reset_ zeroes them atomically
	// so each sample reports only the delta since the last one.
	resp, err := ss.QueryStats(ctx, &statscmd.QueryStatsRequest{Pattern: "user>>>", Reset_: true})
	if err != nil {
		log.Printf("stats query: %v", err)
		return nil
	}
	return statsToItems(resp.GetStat())
}

// statsToItems folds Xray's flat "user>>>{email}>>>traffic>>>{uplink|downlink}"
// counters into per-user up/down totals.
func statsToItems(stats []*statscmd.Stat) []wire.TrafficItem {
	type acc struct{ up, down int64 }
	byEmail := map[string]*acc{}
	for _, s := range stats {
		parts := strings.Split(s.GetName(), ">>>")
		if len(parts) != 4 || parts[0] != "user" || parts[2] != "traffic" {
			continue
		}
		v := s.GetValue()
		if v == 0 {
			continue
		}
		a := byEmail[parts[1]]
		if a == nil {
			a = &acc{}
			byEmail[parts[1]] = a
		}
		switch parts[3] {
		case "uplink":
			a.up += v
		case "downlink":
			a.down += v
		}
	}
	items := make([]wire.TrafficItem, 0, len(byEmail))
	for email, a := range byEmail {
		items = append(items, wire.TrafficItem{Email: email, Up: a.up, Down: a.down})
	}
	return items
}
