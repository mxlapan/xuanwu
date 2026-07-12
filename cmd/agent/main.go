package main

import (
	"fmt"
	"log"
	"os"

	"xuanwu/internal/agent"
)

const usage = `xuanwu-agent — node-side agent

Modes (env MODE or first arg):
  managed      connect to the panel and serve pushed config (default when PANEL_URL set)
  standalone   run a single node with local user management (no panel)

Standalone user management:
  xuanwu-agent user add <name>       add a user, print its share links
  xuanwu-agent user rm <name>        remove a user
  xuanwu-agent user list             list local users
  xuanwu-agent apply                 regenerate config and reload xray
`

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "standalone":
			if err := agent.RunStandalone(agent.ConfigFromEnv()); err != nil {
				log.Fatalf("standalone: %v", err)
			}
			return
		case "managed":
			if err := agent.RunManaged(agent.ConfigFromEnv()); err != nil {
				log.Fatalf("managed: %v", err)
			}
			return
		case "user", "apply":
			if err := agent.RunCLI(agent.ConfigFromEnv(), args); err != nil {
				log.Fatalf("%v", err)
			}
			return
		case "-h", "--help", "help":
			fmt.Print(usage)
			return
		}
	}
	mode := os.Getenv("MODE")
	if mode == "standalone" {
		if err := agent.RunStandalone(agent.ConfigFromEnv()); err != nil {
			log.Fatalf("standalone: %v", err)
		}
		return
	}
	if err := agent.RunManaged(agent.ConfigFromEnv()); err != nil {
		log.Fatalf("managed: %v", err)
	}
}
