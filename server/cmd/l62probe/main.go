// Throwaway probe for L62 (TEAM-9 + MSG-2) against the live local stack.
// Not committed.
//
//	l62probe presence  — teammate pair priya(3, team_level=precise) / omar(10, team_level=approx)
//	l62probe msg       — priya subscribes on Supabase Realtime; omar POSTs a message via PostgREST
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"waypoints/server/internal/wire"
)

const (
	gw      = "ws://127.0.0.1:8080/v1/rt"
	sbWS    = "ws://127.0.0.1:54321/realtime/v1/websocket"
	sbREST  = "http://127.0.0.1:54321/rest/v1/messages"
	channel = "78d0648e-9c00-4a12-93d8-1c4408553c55" // SJIA "general"
)

func env(k string) string {
	v := os.Getenv(k)
	if v == "" {
		panic("missing env " + k)
	}
	return v
}

func tok(file string) string {
	b, err := os.ReadFile(file)
	if err != nil {
		panic(err)
	}
	return strings.TrimSpace(string(b))
}

func main() {
	switch os.Args[1] {
	case "presence":
		presence()
	case "msg":
		msg()
	default:
		panic("mode")
	}
}

// ---------------------------------------------------------------- /v1/rt

type rtConn struct {
	name string
	ws   *websocket.Conn
	uid  uint64

	mu      sync.Mutex
	updates []rec
}

type rec struct {
	at time.Time
	u  *wire.EntityUpdate
}

func rtConnect(ctx context.Context, name, token string) *rtConn {
	ws, _, err := websocket.Dial(ctx, gw, nil)
	if err != nil {
		panic(err)
	}
	c := &rtConn{name: name, ws: ws}
	send(c, &wire.ClientFrame{Body: &wire.ClientFrame_Hello{Hello: &wire.Hello{
		AccessToken: token, Protocol: 1, AppVersion: "l62probe"}}})
	wctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	for {
		f := read(c, wctx)
		if e := f.GetError(); e != nil {
			panic(fmt.Sprintf("%s: %v %s", name, e.Code, e.Message))
		}
		if w := f.GetWelcome(); w != nil {
			c.uid = w.Uid
			fmt.Printf("[%s] welcome uid=%d tick=%dms\n", name, w.Uid, w.TickMs)
			break
		}
	}
	go func() {
		for {
			f := read(c, ctx)
			if f == nil {
				return
			}
			if b := f.GetBatch(); b != nil {
				for _, u := range b.Updates {
					c.mu.Lock()
					c.updates = append(c.updates, rec{time.Now(), u})
					c.mu.Unlock()
					fmt.Printf("[%s] recv uid=%d lat=%d lng=%d hdg=%d tier=%v info=%v\n",
						c.name, u.Uid, u.LatE7, u.LngE7, u.HeadingDeg, u.Tier, u.Info)
				}
				for _, g := range b.Gone {
					fmt.Printf("[%s] gone uid=%d\n", c.name, g)
				}
			}
			if e := f.GetError(); e != nil {
				fmt.Printf("[%s] error %v %s\n", c.name, e.Code, e.Message)
			}
		}
	}()
	return c
}

func send(c *rtConn, f *wire.ClientFrame) {
	b, _ := proto.Marshal(f)
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, b); err != nil {
		panic(err)
	}
}

func read(c *rtConn, ctx context.Context) *wire.ServerFrame {
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		return nil
	}
	var f wire.ServerFrame
	if proto.Unmarshal(data, &f) != nil {
		return nil
	}
	return &f
}

func (c *rtConn) waitFor(uid uint64, since time.Time, d time.Duration) (*wire.EntityUpdate, time.Duration) {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		for _, r := range c.updates {
			if r.u.Uid == uid && !r.at.Before(since) {
				l := r.at.Sub(since)
				c.mu.Unlock()
				return r.u, l
			}
		}
		c.mu.Unlock()
		time.Sleep(5 * time.Millisecond)
	}
	return nil, d
}

func presence() {
	ctx := context.Background()
	priya := rtConnect(ctx, "priya(sub)", tok("/tmp/tok-priya.txt"))
	omar := rtConnect(ctx, "omar(sub)", tok("/tmp/tok-omar.txt"))
	defer priya.ws.CloseNow()
	defer omar.ws.CloseNow()
	time.Sleep(500 * time.Millisecond)

	// 1) omar publishes; team_level=approx -> priya must see APPROX fuzz.
	lat1, lng1 := int32(399612345), int32(-751412345)
	t0 := time.Now()
	send(omar, &wire.ClientFrame{Body: &wire.ClientFrame_Location{Location: &wire.LocationUpdate{
		LatE7: lat1, LngE7: lng1, HeadingDeg: 90, SpeedCms: 1200, AccuracyM: 5,
		ClientMs: uint64(t0.UnixMilli())}}})
	u, lat := priya.waitFor(10, t0, 5*time.Second)
	if u == nil {
		panic("priya never received omar")
	}
	fmt.Printf("=> omar->priya latency %v tier=%v at %d,%d (sent %d,%d) hdg=%d\n",
		lat, u.Tier, u.LatE7, u.LngE7, lat1, lng1, u.HeadingDeg)
	if u.Tier != wire.Tier_APPROX {
		panic(fmt.Sprintf("want APPROX, got %v", u.Tier))
	}
	if u.LatE7 == lat1 && u.LngE7 == lng1 {
		panic("approx update equals exact fix")
	}
	if u.HeadingDeg != 360 {
		panic("approx leaked heading")
	}

	// 2) priya publishes; team_level=precise -> omar must see PRECISE exact.
	lat2, lng2 := int32(399500001), int32(-751300001)
	t1 := time.Now()
	send(priya, &wire.ClientFrame{Body: &wire.ClientFrame_Location{Location: &wire.LocationUpdate{
		LatE7: lat2, LngE7: lng2, HeadingDeg: 270, SpeedCms: 1200, AccuracyM: 5,
		ClientMs: uint64(t1.UnixMilli())}}})
	u2, lat2d := omar.waitFor(3, t1, 5*time.Second)
	if u2 == nil {
		panic("omar never received priya")
	}
	fmt.Printf("=> priya->omar latency %v tier=%v at %d,%d (sent %d,%d) hdg=%d\n",
		lat2d, u2.Tier, u2.LatE7, u2.LngE7, lat2, lng2, u2.HeadingDeg)
	if u2.Tier != wire.Tier_PRECISE || u2.LatE7 != lat2 || u2.LngE7 != lng2 || u2.HeadingDeg != 270 {
		panic("precise update wrong")
	}
	fmt.Println("PRESENCE OK")
}

// ---------------------------------------------------------------- realtime

func msg() {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	anon := env("ANON")
	url := sbWS + "?apikey=" + anon + "&vsn=1.0.0"
	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		panic(err)
	}
	defer ws.CloseNow()

	msgs := make(chan map[string]any, 8)
	go func() {
		for {
			_, data, err := ws.Read(ctx)
			if err != nil {
				return
			}
			fmt.Printf("[rt] %s\n", data)
			var m map[string]any
			if json.Unmarshal(data, &m) == nil {
				msgs <- m
			}
		}
	}()

	topic := "realtime:public:messages:channel_id=eq." + channel
	join := map[string]any{
		"topic": topic, "event": "phx_join", "ref": "1", "join_ref": "1",
		"payload": map[string]any{
			"config": map[string]any{"postgres_changes": []any{map[string]any{
				"event": "INSERT", "schema": "public", "table": "messages",
				"filter": "channel_id=eq." + channel}}},
			"access_token": tok("/tmp/tok-priya.txt"),
		},
	}
	jb, _ := json.Marshal(join)
	if err := ws.Write(ctx, websocket.MessageText, jb); err != nil {
		panic(err)
	}

	// wait for join ok, then the "Subscribed to PostgreSQL" system status
	joined := false
	for m := range msgs {
		if m["event"] == "phx_reply" {
			p := m["payload"].(map[string]any)
			if p["status"] != "ok" {
				panic(fmt.Sprintf("join failed: %v", p))
			}
			joined = true
		}
		if m["event"] == "system" && joined {
			break
		}
	}

	time.Sleep(100 * time.Millisecond)
	body := fmt.Sprintf("l62 live proof %d", time.Now().Unix())
	payload := map[string]any{"channel_id": channel,
		"author_id": "a0000000-0000-4000-8000-000000000010", "body": body}
	pb, _ := json.Marshal(payload)
	req, _ := http.NewRequest("POST", sbREST, bytes.NewReader(pb))
	req.Header.Set("apikey", anon)
	req.Header.Set("Authorization", "Bearer "+tok("/tmp/tok-omar.txt"))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Prefer", "return=representation")
	t0 := time.Now()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		panic(err)
	}
	out, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	fmt.Printf("[rest] %d %s\n", resp.StatusCode, out)
	if resp.StatusCode > 299 {
		panic("insert failed")
	}
	for m := range msgs {
		if m["event"] == "postgres_changes" {
			fmt.Printf("=> realtime fan-out latency %v\n", time.Since(t0))
			fmt.Println("MSG OK")
			return
		}
	}
	panic("no broadcast within timeout")
}
