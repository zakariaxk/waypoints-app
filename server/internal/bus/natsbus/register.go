// Package natsbus implements bus.Bus over NATS core (no JetStream) for
// multi-node mode (section 7.6). It registers only when NATS_URL is set.
package natsbus

import (
	"context"
	"sync"
	"time"

	"github.com/nats-io/nats.go"

	"waypoints/server/internal/app"
	"waypoints/server/internal/bus"
)

// Bus is a NATS-backed bus.Bus.
type Bus struct{ nc *nats.Conn }

// Register connects to NATS_URL and provides the bus.
func Register(a *app.App) {
	if a.Config.NATSURL == "" {
		return
	}
	nc, err := nats.Connect(a.Config.NATSURL, nats.Name("waypoints-"+a.Config.Node), nats.MaxReconnects(-1),
		nats.ReconnectWait(500*time.Millisecond))
	if err != nil {
		a.OnStart("natsbus", func(context.Context) error { return err })
		return
	}
	a.OnStop("natsbus", func(context.Context) error { return nc.Drain() })
	a.Log.Info("bus connected to nats", "url", nc.ConnectedUrl())
	app.Provide[bus.Bus](a, &Bus{nc: nc})
}

func (b *Bus) Local() bool { return false }

func (b *Bus) Publish(subject string, data []byte) error { return b.nc.Publish(subject, data) }

func (b *Bus) Subscribe(subject string, h bus.Handler) (func(), error) {
	sub, err := b.nc.Subscribe(subject, func(m *nats.Msg) {
		msg := bus.Msg{Subject: m.Subject, Data: m.Data}
		if m.Reply != "" {
			msg.Reply = func(data []byte) { _ = m.Respond(data) }
		}
		h(msg)
	})
	if err != nil {
		return func() {}, err
	}
	var once sync.Once
	return func() { once.Do(func() { _ = sub.Unsubscribe() }) }, nil
}

// Request publishes with a reply inbox and collects every reply that arrives
// within window.
func (b *Bus) Request(ctx context.Context, subject string, data []byte, window time.Duration) ([][]byte, error) {
	inbox := nats.NewInbox()
	ch := make(chan *nats.Msg, 64)
	sub, err := b.nc.ChanSubscribe(inbox, ch)
	if err != nil {
		return nil, err
	}
	defer sub.Unsubscribe()
	if err := b.nc.PublishRequest(subject, inbox, data); err != nil {
		return nil, err
	}
	timer := time.NewTimer(window)
	defer timer.Stop()
	var out [][]byte
	for {
		select {
		case m := <-ch:
			out = append(out, m.Data)
		case <-timer.C:
			return out, nil
		case <-ctx.Done():
			return out, ctx.Err()
		}
	}
}
