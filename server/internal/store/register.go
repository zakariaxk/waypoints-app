package store

import (
	"context"
	"fmt"
	"time"

	"waypoints/server/internal/app"
)

// Register provides *Store. With DATABASE_URL it uses Postgres; the pool is
// checked at start, and an unreachable database is fatal in prod but falls
// back to memory (with a warning) in dev and bench.
func Register(a *app.App) {
	s := &Store{pres: &presence{}}
	log := a.Log.With("pkg", "store")

	if a.Config.DatabaseURL == "" {
		s.useMem("DATABASE_URL is not set")
	} else {
		pg, err := newPG(a.Config.DatabaseURL)
		if err != nil {
			if a.Config.Env == "prod" {
				a.OnStart("store", func(context.Context) error { return fmt.Errorf("DATABASE_URL: %w", err) })
			}
			s.useMem("DATABASE_URL is invalid: " + err.Error())
		} else {
			s.b = pg
			a.OnStart("store", func(ctx context.Context) error {
				pctx, cancel := context.WithTimeout(ctx, 5*time.Second)
				defer cancel()
				if err := pg.ping(pctx); err != nil {
					if a.Config.Env == "prod" {
						return fmt.Errorf("postgres: %w", err)
					}
					pg.Close()
					s.useMem("postgres unreachable: " + err.Error())
					log.Warn("store running in memory", "reason", s.reason)
					return nil
				}
				log.Info("store connected to postgres")
				return nil
			})
		}
	}
	if s.mem != nil {
		log.Warn("store running in memory", "reason", s.reason)
	}

	s.mountDev(a.Mux, a.Config.Env == "dev" || a.Config.IsBench())
	a.Go("store-presence", func(ctx context.Context) { s.runPresence(ctx, log) })
	a.OnStop("store", func(context.Context) error { s.b.Close(); return nil })
	app.Provide(a, s)
}

func (s *Store) useMem(reason string) {
	s.mem = newMem()
	s.b = s.mem
	s.reason = reason
}
