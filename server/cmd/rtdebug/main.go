// Command rtdebug is the realtime debug client (PRD 7.1, plan W1-2 acceptance): scripted
// WebSocket clients that sign in with HS256 tokens, drive the gateway through each privacy
// path, and print PASS or FAIL per scenario. It exits 1 if any scenario fails.
//
// The gateway must run with the in-memory store and the /dev seeding endpoints, which is what
// `make check-rt` (tools/dev/check-rt.sh) starts:
//
//	WAYPOINTS_ENV=bench WAYPOINTS_BENCH_SECRET=s DATABASE_URL= SUPABASE_URL= gateway -bench
//	go run ./cmd/rtdebug -url http://127.0.0.1:18180 -metrics http://127.0.0.1:19190 -secret s
//
// Against `make dev`'s gateway (WAYPOINTS_ENV=dev with WAYPOINTS_DEV_JWT_SECRET and no
// database) pass that secret instead. Every scenario mints fresh user ids, so runs never
// interfere with each other or with seed data.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/protobuf/proto"

	"waypoints/server/internal/geo"
	"waypoints/server/internal/wire"
)

var (
	baseURL    = flag.String("url", "http://127.0.0.1:8080", "gateway base URL")
	metricsURL = flag.String("metrics", "", "gateway metrics listener, for the slow-consumer counter (optional)")
	secret     = flag.String("secret", firstEnv("WAYPOINTS_BENCH_SECRET", "WAYPOINTS_DEV_JWT_SECRET"), "HS256 secret the gateway accepts")
	only       = flag.String("only", "", "comma-separated scenario names to run")
	verbose    = flag.Bool("v", false, "log every frame")
)

func firstEnv(keys ...string) string {
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return ""
}

type scenario struct {
	name string
	run  func(ctx context.Context) error
}

func main() {
	flag.Parse()
	if *secret == "" {
		fmt.Fprintln(os.Stderr, "rtdebug: -secret, WAYPOINTS_BENCH_SECRET, or WAYPOINTS_DEV_JWT_SECRET is required")
		os.Exit(2)
	}
	if err := health(); err != nil {
		fmt.Fprintf(os.Stderr, "rtdebug: gateway not reachable at %s: %v\n", *baseURL, err)
		os.Exit(2)
	}
	scenarios := []scenario{
		{"friend-precise", friendPrecise},
		{"approximate", approximate},
		{"hidden", hidden},
		{"ghost", ghost},
		{"nearby-anonymous", nearbyAnonymous},
		{"viewport-swap", viewportSwap},
		{"slow-consumer", slowConsumer},
		{"convoy", convoyScenario},
	}
	want := map[string]bool{}
	for _, n := range strings.Split(*only, ",") {
		if n = strings.TrimSpace(n); n != "" {
			want[n] = true
		}
	}
	failed := 0
	for _, s := range scenarios {
		if len(want) > 0 && !want[s.name] {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		start := time.Now()
		err := s.run(ctx)
		cancel()
		took := time.Since(start).Round(10 * time.Millisecond)
		if err != nil {
			failed++
			fmt.Printf("FAIL  %-18s %v (%s)\n", s.name, err, took)
		} else {
			fmt.Printf("PASS  %-18s (%s)\n", s.name, took)
		}
	}
	if failed > 0 {
		fmt.Printf("%d scenario(s) failed\n", failed)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------- scenarios

// Philadelphia, City Hall. Each scenario offsets its own area so cells never overlap.
const baseLat, baseLng = 39.9526, -75.1652

func spot(n int) (int32, int32) {
	return geo.E7(baseLat + float64(n)*0.2), geo.E7(baseLng)
}

// A friend sharing Precise is delivered at the exact point, with heading and identity.
func friendPrecise(ctx context.Context) error {
	a, b := newUser("Marcus Reyes", "2006 Honda S2000"), newUser("Priya Natarajan", "2022 Subaru WRX")
	if err := friends(a, b); err != nil {
		return err
	}
	pub, sub, err := pair(ctx, a, b)
	if err != nil {
		return err
	}
	defer pub.close()
	defer sub.close()
	lat, lng := spot(1)
	pub.location(ctx, lat, lng, 90)
	u, err := sub.waitUpdate(pub.uid, 3*time.Second, nil)
	if err != nil {
		return err
	}
	switch {
	case u.Tier != wire.Tier_PRECISE:
		return fmt.Errorf("tier %v, want PRECISE", u.Tier)
	case u.LatE7 != lat || u.LngE7 != lng:
		return fmt.Errorf("got %d,%d, want exact %d,%d", u.LatE7, u.LngE7, lat, lng)
	case u.HeadingDeg != 90:
		return fmt.Errorf("heading %d, want 90", u.HeadingDeg)
	}
	info := sub.infoFor(pub.uid)
	if info == nil || info.Relation != wire.Relation_FRIEND || info.DisplayName != a.name {
		return fmt.Errorf("info %v, want FRIEND %q", info, a.name)
	}
	return nil
}

// Friends at Approximate get the resolution 8 cell centre, no heading, and no new position
// sooner than 15 s after the last, however often the publisher moves.
func approximate(ctx context.Context) error {
	a, b := newUser("Dana Whitfield", "2019 Volkswagen Golf GTI"), newUser("Tom Kowalski", "1999 Mazda MX-5 Miata")
	if err := friends(a, b); err != nil {
		return err
	}
	if err := putPrivacy(a, map[string]any{"friends_level": "approx"}); err != nil {
		return err
	}
	pub, sub, err := pair(ctx, a, b)
	if err != nil {
		return err
	}
	defer pub.close()
	defer sub.close()
	lat, lng := spot(2)
	wantLat, wantLng := geo.Approximate(lat, lng)
	pub.location(ctx, lat, lng, 45)
	u, err := sub.waitUpdate(pub.uid, 3*time.Second, nil)
	if err != nil {
		return err
	}
	if u.Tier != wire.Tier_APPROX || u.HeadingDeg != 360 {
		return fmt.Errorf("tier %v heading %d, want APPROX and 360", u.Tier, u.HeadingDeg)
	}
	if u.LatE7 != wantLat || u.LngE7 != wantLng {
		return fmt.Errorf("got %d,%d, want cell centre %d,%d", u.LatE7, u.LngE7, wantLat, wantLng)
	}
	if u.LatE7 == lat && u.LngE7 == lng {
		return errors.New("approximate equals the exact fix")
	}
	// Move about 1.5 km over 5 s; nothing new may arrive inside the 15 s window.
	for i := 1; i <= 8; i++ {
		sleep(ctx, 600*time.Millisecond)
		pub.location(ctx, lat+int32(i)*17000, lng+int32(i)*17000, 45)
	}
	sleep(ctx, time.Second)
	for _, r := range sub.updatesFor(pub.uid) {
		if r.u.Tier != wire.Tier_APPROX {
			return fmt.Errorf("a %v update leaked", r.u.Tier)
		}
		if r.u.LatE7 != wantLat || r.u.LngE7 != wantLng {
			return fmt.Errorf("new approximate position %d,%d inside 15 s", r.u.LatE7, r.u.LngE7)
		}
	}
	return nil
}

// A friend at Hidden gets nothing.
func hidden(ctx context.Context) error {
	a, b := newUser("Jaylen Brooks", "2003 BMW M3"), newUser("Sofia Moretti", "2001 Volkswagen Jetta")
	if err := friends(a, b); err != nil {
		return err
	}
	if err := putPrivacy(a, map[string]any{"friends_level": "hidden", "team_level": "hidden", "nearby_level": "hidden"}); err != nil {
		return err
	}
	pub, sub, err := pair(ctx, a, b)
	if err != nil {
		return err
	}
	defer pub.close()
	defer sub.close()
	lat, lng := spot(3)
	lo, hi := geo.E7(baseLat+0.6-0.02), geo.E7(baseLat+0.6+0.02)
	sub.viewport(ctx, lo, lng-200000, hi, lng+200000)
	for i := range 4 {
		pub.location(ctx, lat+int32(i)*1000, lng, 0)
		sleep(ctx, 500*time.Millisecond)
	}
	sleep(ctx, time.Second)
	if n := len(sub.updatesFor(pub.uid)); n > 0 {
		return fmt.Errorf("%d update(s) delivered while hidden", n)
	}
	return nil
}

// Turning on ghost mode sends gone and stops delivery within one tick.
func ghost(ctx context.Context) error {
	a, b := newUser("Ray Delgado", "1989 Ford Mustang GT"), newUser("Kenji Watanabe", "2017 Toyota 86")
	if err := friends(a, b); err != nil {
		return err
	}
	pub, sub, err := pair(ctx, a, b)
	if err != nil {
		return err
	}
	defer pub.close()
	defer sub.close()
	lat, lng := spot(4)
	pub.location(ctx, lat, lng, 180)
	if _, err := sub.waitUpdate(pub.uid, 3*time.Second, nil); err != nil {
		return fmt.Errorf("before ghost: %w", err)
	}
	start := time.Now()
	if err := putPrivacy(a, map[string]any{"ghost_until": time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}); err != nil {
		return err
	}
	tick := time.Duration(sub.tickMs) * time.Millisecond
	limit := tick + 150*time.Millisecond // one tick plus loopback and scheduling slack
	at, err := sub.waitGone(pub.uid, start, 2*time.Second)
	if err != nil {
		return err
	}
	if took := at.Sub(start); took > limit {
		return fmt.Errorf("gone after %s, want within one tick (%s)", took.Round(time.Millisecond), tick)
	}
	n := len(sub.updatesFor(pub.uid))
	for i := 1; i <= 3; i++ {
		sleep(ctx, 500*time.Millisecond)
		pub.location(ctx, lat+int32(i)*1000, lng, 180)
	}
	sleep(ctx, 500*time.Millisecond)
	if m := len(sub.updatesFor(pub.uid)); m > n {
		return fmt.Errorf("%d update(s) after ghost", m-n)
	}
	return nil
}

// A stranger sharing Nearby is seen through the viewport as approximate, with no name, no car,
// and no heading.
func nearbyAnonymous(ctx context.Context) error {
	a, b := newUser("Alexis Grant", "2023 Honda Civic Type R"), newUser("Omar Haddad", "2005 Nissan 350Z")
	if err := putPrivacy(a, map[string]any{"nearby_level": "approx"}); err != nil {
		return err
	}
	pub, sub, err := pair(ctx, a, b)
	if err != nil {
		return err
	}
	defer pub.close()
	defer sub.close()
	lat, lng := spot(5)
	sub.viewport(ctx, lat-150000, lng-150000, lat+150000, lng+150000)
	sleep(ctx, 200*time.Millisecond)
	pub.location(ctx, lat, lng, 270)
	u, err := sub.waitUpdate(pub.uid, 3*time.Second, nil)
	if err != nil {
		return err
	}
	if u.Tier != wire.Tier_APPROX || u.HeadingDeg != 360 {
		return fmt.Errorf("tier %v heading %d, want APPROX and 360", u.Tier, u.HeadingDeg)
	}
	info := sub.infoFor(pub.uid)
	if info == nil {
		return errors.New("no EntityInfo on first appearance")
	}
	if info.Relation != wire.Relation_NEARBY {
		return fmt.Errorf("relation %v, want NEARBY", info.Relation)
	}
	if info.DisplayName != "" || info.CarLabel != "" {
		return fmt.Errorf("identity leaked: name %q car %q", info.DisplayName, info.CarLabel)
	}
	return nil
}

// Moving the viewport away unsubscribes the old cells and sends gone for what was in them.
func viewportSwap(ctx context.Context) error {
	a, b := newUser("Bree Lawson", "2020 Toyota GR Supra"), newUser("Nick Ferraro", "2008 Mitsubishi Lancer Evolution")
	if err := putPrivacy(a, map[string]any{"nearby_level": "approx"}); err != nil {
		return err
	}
	pub, sub, err := pair(ctx, a, b)
	if err != nil {
		return err
	}
	defer pub.close()
	defer sub.close()
	lat, lng := spot(6)
	sub.viewport(ctx, lat-150000, lng-150000, lat+150000, lng+150000)
	sleep(ctx, 200*time.Millisecond)
	pub.location(ctx, lat, lng, 0)
	if _, err := sub.waitUpdate(pub.uid, 3*time.Second, nil); err != nil {
		return fmt.Errorf("in view: %w", err)
	}
	start := time.Now()
	far := lat + 5000000 // 0.5 degrees north
	sub.viewport(ctx, far-150000, lng-150000, far+150000, lng+150000)
	if _, err := sub.waitGone(pub.uid, start, 2*time.Second); err != nil {
		return fmt.Errorf("after swap: %w", err)
	}
	n := len(sub.updatesFor(pub.uid))
	sleep(ctx, 500*time.Millisecond)
	pub.location(ctx, lat+500, lng, 0)
	sleep(ctx, 700*time.Millisecond)
	if m := len(sub.updatesFor(pub.uid)); m > n {
		return fmt.Errorf("%d update(s) from the old viewport", m-n)
	}
	return nil
}

// A reader that stops reading while its reliable lane fills is closed with 4008, and a healthy
// viewer of the same publisher keeps receiving meanwhile.
func slowConsumer(ctx context.Context) error {
	a, b, s := newUser("Marcus Reyes", "2006 Honda S2000"), newUser("Priya Natarajan", "2022 Subaru WRX"),
		newUser("Stalled Reader", "")
	for _, x := range [][2]*user{{a, b}, {a, s}} {
		if err := friends(x[0], x[1]); err != nil {
			return err
		}
	}
	before := slowClosedCount()
	pub, err := connect(ctx, a, false)
	if err != nil {
		return err
	}
	defer pub.close()
	good, err := connect(ctx, b, false)
	if err != nil {
		return err
	}
	defer good.close()
	stalled, err := connect(ctx, s, true)
	if err != nil {
		return err
	}
	defer stalled.close()

	// Flood pings: every Pong goes on the stalled client's reliable lane.
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := uint64(0); ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			if stalled.send(ctx, &wire.ClientFrame{Body: &wire.ClientFrame_Ping{Ping: &wire.Ping{ClientMs: i}}}) != nil {
				return
			}
		}
	}()
	// Meanwhile the publisher drives and the healthy viewer must keep up.
	lat, lng := spot(7)
	var lag time.Duration
	for i := range 12 {
		sent := time.Now()
		pub.location(ctx, lat+int32(i)*800, lng, 0)
		want := lat + int32(i)*800
		if _, err := good.waitUpdate(pub.uid, 2*time.Second, func(u *wire.EntityUpdate) bool { return u.LatE7 == want }); err != nil {
			close(stop)
			wg.Wait()
			return fmt.Errorf("healthy viewer delayed: %w", err)
		}
		lag = max(lag, time.Since(sent))
		sleep(ctx, 500*time.Millisecond)
	}
	close(stop)
	wg.Wait()

	code, err := stalled.drainClose(ctx, 10*time.Second)
	after := slowClosedCount()
	if code == 4008 {
		return nil
	}
	if before >= 0 && after > before {
		return nil // closed for slow consumer; the close frame itself could not be written
	}
	return fmt.Errorf("stalled reader not closed with 4008 (close %d, err %v, healthy max lag %s)", code, err, lag.Round(time.Millisecond))
}

// Convoy members see each other precisely even when every audience is hidden, and stop
// seeing each other after leaving.
func convoyScenario(ctx context.Context) error {
	a, b := newUser("Priya Natarajan", "2004 Subaru Impreza WRX STI"), newUser("Kenji Watanabe", "1986 Toyota Corolla GT-S")
	if err := putPrivacy(a, map[string]any{"friends_level": "hidden", "team_level": "hidden", "nearby_level": "hidden"}); err != nil {
		return err
	}
	var created struct {
		ID       string `json:"id"`
		JoinCode string `json:"join_code"`
	}
	if err := api(http.MethodPost, "/v1/convoys", a, map[string]any{"name": "Route 206 run"}, &created); err != nil {
		return fmt.Errorf("create: %w", err)
	}
	if err := api(http.MethodPost, "/v1/convoys/join", b, map[string]any{"join_code": created.JoinCode}, nil); err != nil {
		return fmt.Errorf("join: %w", err)
	}
	pub, sub, err := pair(ctx, a, b)
	if err != nil {
		return err
	}
	defer pub.close()
	defer sub.close()
	for _, c := range []*client{pub, sub} {
		_ = c.send(ctx, &wire.ClientFrame{Body: &wire.ClientFrame_JoinConvoy{JoinConvoy: &wire.JoinConvoy{ConvoyId: created.ID}}})
	}
	if err := sub.waitConvoy(3 * time.Second); err != nil {
		return err
	}
	sleep(ctx, 200*time.Millisecond)
	lat, lng := spot(8)
	pub.location(ctx, lat, lng, 135)
	u, err := sub.waitUpdate(pub.uid, 3*time.Second, nil)
	if err != nil {
		return err
	}
	if u.Tier != wire.Tier_PRECISE || u.LatE7 != lat || u.LngE7 != lng {
		return fmt.Errorf("got %v %d,%d, want PRECISE %d,%d", u.Tier, u.LatE7, u.LngE7, lat, lng)
	}
	if info := sub.infoFor(pub.uid); info == nil || info.Relation != wire.Relation_CONVOY {
		return fmt.Errorf("info %v, want CONVOY", info)
	}
	start := time.Now()
	_ = sub.send(ctx, &wire.ClientFrame{Body: &wire.ClientFrame_LeaveConvoy{LeaveConvoy: &wire.LeaveConvoy{}}})
	if _, err := sub.waitGone(pub.uid, start, 2*time.Second); err != nil {
		return fmt.Errorf("after leave: %w", err)
	}
	n := len(sub.updatesFor(pub.uid))
	for i := 1; i <= 3; i++ {
		sleep(ctx, 500*time.Millisecond)
		pub.location(ctx, lat+int32(i)*1000, lng, 135)
	}
	sleep(ctx, 500*time.Millisecond)
	if m := len(sub.updatesFor(pub.uid)); m > n {
		return fmt.Errorf("%d update(s) after leaving", m-n)
	}
	return nil
}

// ---------------------------------------------------------------- users and HTTP

type user struct {
	id, name, car string
}

func newUser(name, car string) *user {
	var b [6]byte
	_, _ = rand.Read(b[:])
	u := &user{id: fmt.Sprintf("7d000000-0000-4000-8000-%x", b), name: name, car: car}
	_ = post("/dev/profile", map[string]any{"user_id": u.id, "display_name": name, "marker_icon": "coupe", "car_label": car})
	return u
}

func (u *user) token() string {
	t, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": u.id, "aud": "authenticated", "role": "authenticated", "exp": time.Now().Add(time.Hour).Unix(),
	}).SignedString([]byte(*secret))
	return t
}

func friends(a, b *user) error { return post("/dev/friends", map[string]string{"a": a.id, "b": b.id}) }

func putPrivacy(u *user, body map[string]any) error { return api(http.MethodPut, "/v1/privacy", u, body, nil) }

func health() error {
	resp, err := http.Get(*baseURL + "/healthz")
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New(resp.Status)
	}
	return nil
}

func post(path string, body any) error {
	b, _ := json.Marshal(body)
	resp, err := http.Post(*baseURL+path, "application/json", bytes.NewReader(b))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("%s: %s (the gateway needs the in-memory store and WAYPOINTS_ENV=dev or bench)", path, resp.Status)
	}
	return nil
}

func api(method, path string, u *user, body, out any) error {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, *baseURL+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+u.token())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("%s %s: %s %s", method, path, resp.Status, strings.TrimSpace(string(msg)))
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

// slowClosedCount reads ws_slow_consumer_closed_total, or -1 when metrics are not available.
func slowClosedCount() float64 {
	if *metricsURL == "" {
		return -1
	}
	resp, err := http.Get(*metricsURL + "/metrics")
	if err != nil {
		return -1
	}
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "ws_slow_consumer_closed_total") {
			f := strings.Fields(line)
			if v, err := strconv.ParseFloat(f[len(f)-1], 64); err == nil {
				return v
			}
		}
	}
	return -1
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

// ---------------------------------------------------------------- client

type rec struct {
	at time.Time
	u  *wire.EntityUpdate
}

type client struct {
	u      *user
	ws     *websocket.Conn
	uid    uint64
	tickMs uint32

	mu      sync.Mutex
	updates []rec
	gone    map[uint64][]time.Time
	info    map[uint64]*wire.EntityInfo
	convoy  *wire.ConvoyState
	closed  error
	lastLoc time.Time
	done    chan struct{}
}

// pair connects a publisher and a subscriber.
func pair(ctx context.Context, a, b *user) (*client, *client, error) {
	pub, err := connect(ctx, a, false)
	if err != nil {
		return nil, nil, err
	}
	sub, err := connect(ctx, b, false)
	if err != nil {
		pub.close()
		return nil, nil, err
	}
	return pub, sub, nil
}

// connect dials /v1/rt, says Hello, and waits for Welcome. A stalled client shrinks its
// socket receive buffer and never reads after Welcome until drainClose.
func connect(ctx context.Context, u *user, stalled bool) (*client, error) {
	target := strings.Replace(*baseURL, "http", "ws", 1) + "/v1/rt"
	opts := &websocket.DialOptions{}
	if stalled {
		d := &net.Dialer{}
		opts.HTTPClient = &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			c, err := d.DialContext(ctx, network, addr)
			if tc, ok := c.(*net.TCPConn); ok {
				_ = tc.SetReadBuffer(4096)
			}
			return c, err
		}}}
	}
	ws, _, err := websocket.Dial(ctx, target, opts)
	if err != nil {
		return nil, fmt.Errorf("dial: %w", err)
	}
	ws.SetReadLimit(1 << 20)
	c := &client{u: u, ws: ws, gone: map[uint64][]time.Time{}, info: map[uint64]*wire.EntityInfo{}, done: make(chan struct{})}
	if err := c.send(ctx, &wire.ClientFrame{Body: &wire.ClientFrame_Hello{Hello: &wire.Hello{AccessToken: u.token(), Protocol: 1, AppVersion: "rtdebug"}}}); err != nil {
		ws.CloseNow()
		return nil, err
	}
	wctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	for {
		f, err := c.readFrame(wctx)
		if err != nil {
			ws.CloseNow()
			return nil, fmt.Errorf("waiting for welcome (%s): %w", u.name, err)
		}
		if e := f.GetError(); e != nil {
			ws.CloseNow()
			return nil, fmt.Errorf("server error %v: %s", e.Code, e.Message)
		}
		if w := f.GetWelcome(); w != nil {
			c.uid, c.tickMs = w.Uid, w.TickMs
			break
		}
	}
	if !stalled {
		go c.readLoop(ctx)
	}
	return c, nil
}

func (c *client) readFrame(ctx context.Context) (*wire.ServerFrame, error) {
	_, data, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	var f wire.ServerFrame
	if err := proto.Unmarshal(data, &f); err != nil {
		return nil, err
	}
	return &f, nil
}

func (c *client) readLoop(ctx context.Context) {
	defer close(c.done)
	for {
		f, err := c.readFrame(ctx)
		if err != nil {
			c.mu.Lock()
			c.closed = err
			c.mu.Unlock()
			return
		}
		c.record(f)
	}
}

func (c *client) record(f *wire.ServerFrame) {
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()
	if *verbose {
		fmt.Printf("    %s <- %v\n", c.u.name, f)
	}
	if b := f.GetBatch(); b != nil {
		for _, u := range b.Updates {
			c.updates = append(c.updates, rec{now, u})
			if u.Info != nil {
				c.info[u.Uid] = u.Info
			}
		}
		for _, g := range b.Gone {
			c.gone[g] = append(c.gone[g], now)
		}
	}
	if cs := f.GetConvoy(); cs != nil {
		c.convoy = cs
	}
}

func (c *client) send(ctx context.Context, f *wire.ClientFrame) error {
	b, _ := proto.Marshal(f)
	return c.ws.Write(ctx, websocket.MessageBinary, b)
}

// location respects the gateway's 400 ms minimum interval so no fix is dropped.
func (c *client) location(ctx context.Context, lat, lng int32, heading uint32) {
	if wait := 450*time.Millisecond - time.Since(c.lastLoc); wait > 0 {
		sleep(ctx, wait)
	}
	c.lastLoc = time.Now()
	_ = c.send(ctx, &wire.ClientFrame{Body: &wire.ClientFrame_Location{Location: &wire.LocationUpdate{
		LatE7: lat, LngE7: lng, HeadingDeg: heading, SpeedCms: 1200, AccuracyM: 5, ClientMs: uint64(time.Now().UnixMilli()),
	}}})
}

func (c *client) viewport(ctx context.Context, minLat, minLng, maxLat, maxLng int32) {
	_ = c.send(ctx, &wire.ClientFrame{Body: &wire.ClientFrame_Viewport{Viewport: &wire.SetViewport{
		MinLatE7: minLat, MinLngE7: minLng, MaxLatE7: maxLat, MaxLngE7: maxLng,
	}}})
}

func (c *client) updatesFor(uid uint64) []rec {
	c.mu.Lock()
	defer c.mu.Unlock()
	var out []rec
	for _, r := range c.updates {
		if r.u.Uid == uid {
			out = append(out, r)
		}
	}
	return out
}

func (c *client) infoFor(uid uint64) *wire.EntityInfo {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.info[uid]
}

// waitUpdate returns the newest update for uid that matches pred (nil: any).
func (c *client) waitUpdate(uid uint64, timeout time.Duration, pred func(*wire.EntityUpdate) bool) (*wire.EntityUpdate, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		rs := c.updatesFor(uid)
		for i := len(rs) - 1; i >= 0; i-- {
			if pred == nil || pred(rs[i].u) {
				return rs[i].u, nil
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	return nil, fmt.Errorf("no update for uid %d within %s", uid, timeout)
}

// waitGone returns when uid appeared in a gone list after since.
func (c *client) waitGone(uid uint64, since time.Time, timeout time.Duration) (time.Time, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		for _, t := range c.gone[uid] {
			if !t.Before(since) {
				c.mu.Unlock()
				return t, nil
			}
		}
		c.mu.Unlock()
		time.Sleep(5 * time.Millisecond)
	}
	return time.Time{}, fmt.Errorf("no gone for uid %d within %s", uid, timeout)
}

func (c *client) waitConvoy(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		ok := c.convoy != nil
		c.mu.Unlock()
		if ok {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
	return errors.New("no ConvoyState after JoinConvoy")
}

// drainClose reads until the connection ends and returns the close code (-1 if none).
func (c *client) drainClose(ctx context.Context, timeout time.Duration) (websocket.StatusCode, error) {
	rctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	for {
		if _, _, err := c.ws.Read(rctx); err != nil {
			return websocket.CloseStatus(err), err
		}
	}
}

func (c *client) close() { c.ws.CloseNow() }
