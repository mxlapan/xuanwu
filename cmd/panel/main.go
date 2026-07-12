package main

import (
	"log"

	"xuanwu/internal/panel"
)

func main() {
	if err := panel.Run(panel.ConfigFromEnv()); err != nil {
		log.Fatalf("panel: %v", err)
	}
}
