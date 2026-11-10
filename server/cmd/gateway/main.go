// Command gateway is the Waypoints realtime gateway: WebSocket fan-out of live
// location plus a small JSON API. See docs/PLAN.md sections 6 and 7, and
// server/README.md for configuration.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"waypoints/server/internal/api"
	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/bus"
	"waypoints/server/internal/bus/natsbus"
	"waypoints/server/internal/convoy"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/hub"
	"waypoints/server/internal/privacy"
	"waypoints/server/internal/push"
	"waypoints/server/internal/store"
	"waypoints/server/internal/voice"
	"waypoints/server/internal/ws"
)

// registrations run in this order. A package may MustLookup a service only
// from packages above it. Packages declare their own command-line flags at
// package level; flag.Parse runs before any Register.
var registrations = []struct {
	name     string
	register func(*app.App)
}{
	{"store", store.Register},     // Postgres pool
	{"bus", bus.Register},         // in-process bus
	{"natsbus", natsbus.Register}, // replaces the bus when NATS_URL is set
	{"auth", auth.Register},
	{"geo", geo.Register},
	{"privacy", privacy.Register},
	{"hub", hub.Register},
	{"push", push.Register},
	{"ws", ws.Register}, // /v1/rt
	{"api", api.Register},
	{"convoy", convoy.Register},
	{"voice", voice.Register},
}

func main() {
	flag.Parse()

	cfg, err := app.LoadConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "gateway: config:", err)
		os.Exit(2)
	}

	a := app.New(cfg)
	for _, r := range registrations {
		r.register(a)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := a.Run(ctx); err != nil {
		a.Log.Error("gateway exited", "err", err)
		stop()
		os.Exit(1)
	}
}
