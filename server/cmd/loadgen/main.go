// Command loadgen drives a gateway running with WAYPOINTS_ENV=bench and -bench: it seeds
// profiles and friend groups through /dev, opens one WebSocket per simulated driver, publishes
// location at a fixed rate, and measures publish-to-delivery latency from origin_ms (plan 8.2).
//
//	go run ./cmd/loadgen -url http://127.0.0.1:8080 -clients 200 -group 10 -hz 1 -duration 20s
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/protobuf/proto"

	"waypoints/server/internal/wire"
)

type result struct {
	Scenario      string  `json:"scenario"`
	Clients       int     `json:"clients"`
	Group         int     `json:"group"`
	Hz            float64 `json:"hz"`
	TickMs        int     `json:"tick_ms"`
	Seconds       float64 `json:"seconds"`
	Published     int64   `json:"published"`
	Deliveries    int64   `json:"deliveries"`
	DeliveriesSec float64 `json:"deliveries_per_sec"`
	BytesPerDeliv float64 `json:"bytes_per_delivery"`
	P50Ms         float64 `json:"p50_ms"`
	P99Ms         float64 `json:"p99_ms"`
	P999Ms        float64 `json:"p999_ms"`
	Errors        int64   `json:"errors"`
}

func main() {
	base := flag.String("url", "http://127.0.0.1:8080", "gateway base URL")
	base2 := flag.String("url2", "", "second gateway node; odd-numbered clients connect here, so friends span both nodes")
	clients := flag.Int("clients", 200, "simulated drivers")
	group := flag.Int("group", 10, "friends per group (everyone in a group is friends with everyone else)")
	hz := flag.Float64("hz", 1, "location updates per second per driver")
	duration := flag.Duration("duration", 20*time.Second, "measurement window")
	secret := flag.String("secret", os.Getenv("WAYPOINTS_BENCH_SECRET"), "HS256 secret the gateway accepts with -bench")
	scenario := flag.String("scenario", "", "label for the results")
	out := flag.String("out", "", "append the result as one JSON line to this file")
	flag.Parse()
	if *secret == "" {
		log.Fatal("loadgen: -secret or WAYPOINTS_BENCH_SECRET is required")
	}

	// Each node keeps its own in-memory store in bench mode, so every node gets the seed.
	bases := []string{*base}
	if *base2 != "" {
		bases = append(bases, *base2)
	}
	seed := func(path string, body any) {
		for _, b := range bases {
			post(b+path, body)
		}
	}
	ids := make([]string, *clients)
	for i := range ids {
		ids[i] = fmt.Sprintf("00000000-0000-4000-8000-%012d", i+1)
		seed("/dev/profile", map[string]any{"user_id": ids[i], "display_name": fmt.Sprintf("Driver %d", i+1), "marker_icon": "coupe"})
	}
	for g := 0; g < len(ids); g += *group {
		end := min(g+*group, len(ids))
		for a := g; a < end; a++ {
			for b := a + 1; b < end; b++ {
				seed("/dev/friends", map[string]string{"a": ids[a], "b": ids[b]})
			}
		}
	}

	ws := strings.Replace(*base, "http", "ws", 1) + "/v1/rt"
	ws2 := ws
	if *base2 != "" {
		ws2 = strings.Replace(*base2, "http", "ws", 1) + "/v1/rt"
	}
	var (
		published, deliveries, bytesIn, errs atomic.Int64
		mu                                   sync.Mutex
		lat                                  []float64
		tickMs                               atomic.Int64
	)
	ctx, cancel := context.WithTimeout(context.Background(), *duration+5*time.Second)
	defer cancel()
	measureFrom := time.Now().Add(3 * time.Second)
	measureTo := measureFrom.Add(*duration)

	var wg sync.WaitGroup
	for i, id := range ids {
		wg.Add(1)
		go func(i int, id string) {
			defer wg.Done()
			tok, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"sub": id, "exp": time.Now().Add(time.Hour).Unix()}).
				SignedString([]byte(*secret))
			target := ws
			if i%2 == 1 {
				target = ws2
			}
			c, _, err := websocket.Dial(ctx, target, nil)
			if err != nil {
				errs.Add(1)
				return
			}
			defer c.CloseNow()
			c.SetReadLimit(1 << 20)
			send := func(f *wire.ClientFrame) error {
				b, _ := proto.Marshal(f)
				return c.Write(ctx, websocket.MessageBinary, b)
			}
			if send(&wire.ClientFrame{Body: &wire.ClientFrame_Hello{Hello: &wire.Hello{AccessToken: tok, Protocol: 1, AppVersion: "loadgen"}}}) != nil {
				errs.Add(1)
				return
			}
			// Groups drive around different points so cells do not overlap across groups.
			lat0 := 39.9 + float64(i / *group)*0.05
			lng0 := -75.1
			go func() {
				t := time.NewTicker(time.Duration(float64(time.Second) / *hz))
				defer t.Stop()
				a := rand.Float64() * 2 * math.Pi
				for {
					select {
					case <-ctx.Done():
						return
					case <-t.C:
					}
					a += 0.01
					f := &wire.ClientFrame{Body: &wire.ClientFrame_Location{Location: &wire.LocationUpdate{
						LatE7: int32((lat0 + 0.01*math.Sin(a)) * 1e7), LngE7: int32((lng0 + 0.01*math.Cos(a)) * 1e7),
						HeadingDeg: 90, SpeedCms: 1500, AccuracyM: 5, ClientMs: uint64(time.Now().UnixMilli()),
					}}}
					if send(f) != nil {
						return
					}
					if now := time.Now(); now.After(measureFrom) && now.Before(measureTo) {
						published.Add(1)
					}
				}
			}()
			for {
				_, data, err := c.Read(ctx)
				if err != nil {
					return
				}
				var f wire.ServerFrame
				if proto.Unmarshal(data, &f) != nil {
					continue
				}
				if w := f.GetWelcome(); w != nil {
					tickMs.Store(int64(w.TickMs))
				}
				b := f.GetBatch()
				if b == nil {
					continue
				}
				now := time.Now()
				if now.Before(measureFrom) || now.After(measureTo) {
					continue
				}
				bytesIn.Add(int64(len(data)))
				ms := float64(now.UnixMilli())
				mu.Lock()
				for _, u := range b.Updates {
					if u.OriginMs > 0 {
						lat = append(lat, ms-float64(u.OriginMs))
					}
				}
				mu.Unlock()
				deliveries.Add(int64(len(b.Updates)))
			}
		}(i, id)
	}
	wg.Wait()

	sort.Float64s(lat)
	pct := func(p float64) float64 {
		if len(lat) == 0 {
			return 0
		}
		return lat[min(len(lat)-1, int(p*float64(len(lat))))]
	}
	secs := duration.Seconds()
	r := result{Scenario: *scenario, Clients: *clients, Group: *group, Hz: *hz, TickMs: int(tickMs.Load()), Seconds: secs,
		Published: published.Load(), Deliveries: deliveries.Load(), DeliveriesSec: float64(deliveries.Load()) / secs,
		P50Ms: pct(0.5), P99Ms: pct(0.99), P999Ms: pct(0.999), Errors: errs.Load()}
	if r.Deliveries > 0 {
		r.BytesPerDeliv = float64(bytesIn.Load()) / float64(r.Deliveries)
	}
	line, _ := json.Marshal(r)
	fmt.Println(string(line))
	if *out != "" {
		f, err := os.OpenFile(*out, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			log.Fatal(err)
		}
		defer f.Close()
		_, _ = f.Write(append(line, '\n'))
	}
}

func post(url string, body any) {
	b, _ := json.Marshal(body)
	resp, err := http.Post(url, "application/json", bytes.NewReader(b))
	if err != nil {
		log.Fatalf("loadgen: %s: %v", url, err)
	}
	resp.Body.Close()
	if resp.StatusCode >= 300 {
		log.Fatalf("loadgen: %s: %s (is the gateway running with WAYPOINTS_ENV=bench and no DATABASE_URL?)", url, resp.Status)
	}
}
