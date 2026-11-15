// Command loadgen drives a gateway running with WAYPOINTS_ENV=bench and -bench: it seeds
// profiles and friend groups through /dev, opens one WebSocket per simulated driver, publishes
// location at a fixed rate, and measures publish-to-delivery latency from origin_ms (plan 8.2).
//
//	go run ./cmd/loadgen -url http://127.0.0.1:8080 -clients 200 -group 10 -hz 1 -duration 20s
//
// Scenarios beyond plain fan-out (plan 8.1):
//
//	-hz 0 -ping 25s          idle connections with heartbeats; pair with -pid for memory per connection
//	-stall 0.05              5% of subscribers stop reading when measurement starts
//	-storm                   every connection drops at a quarter of the window and returns within -storm-spread
//	-ports 10000-60000       bind local ports explicitly (beyond the 16k ephemeral range on macOS)
//	-src 127.0.0.1,127.0.0.2 spread connections over source addresses (plan 8.2)
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand/v2"
	"net"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/exec"
	"runtime/pprof"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/golang-jwt/jwt/v5"
	"google.golang.org/protobuf/proto"

	"waypoints/server/internal/wire"
)

type result struct {
	Scenario      string  `json:"scenario"`
	Label         string  `json:"label,omitempty"`
	Clients       int     `json:"clients"`
	Connected     int64   `json:"connected"`
	Group         int     `json:"group"`
	Hz            float64 `json:"hz"`
	TickMs        int     `json:"tick_ms"`
	Nodes         int     `json:"nodes"`
	Seconds       float64 `json:"seconds"`
	ConnectS      float64 `json:"connect_s"`
	Published     int64   `json:"published"`
	Deliveries    int64   `json:"deliveries"`
	DeliveriesSec float64 `json:"deliveries_per_sec"`
	BytesPerDeliv float64 `json:"bytes_per_delivery"`
	P50Ms         float64 `json:"p50_ms"`
	P90Ms         float64 `json:"p90_ms"`
	P99Ms         float64 `json:"p99_ms"`
	P999Ms        float64 `json:"p999_ms"`
	MaxMs         float64 `json:"max_ms"`
	// First delivery of each publisher to each connection is the subscribe-time snapshot of
	// the last-known position, whose origin can be up to one publish interval old. It is left
	// out of the percentiles above and counted here; Raw* include it.
	FirstExcluded int64   `json:"first_excluded"`
	RawP999Ms     float64 `json:"raw_p999_ms"`
	RawMaxMs      float64 `json:"raw_max_ms"`
	Errors        int64   `json:"errors"`
	// Two nodes: deliveries whose publisher is on the other node.
	CrossP50Ms      float64 `json:"cross_node_p50_ms,omitempty"`
	CrossP99Ms      float64 `json:"cross_node_p99_ms,omitempty"`
	CrossP999Ms     float64 `json:"cross_node_p999_ms,omitempty"`
	UpdatesPerFrame float64 `json:"updates_per_frame,omitempty"`
	// Latency minus the gateway-reported age (100 ms resolution): the publisher-to-gateway leg
	// plus up to 100 ms of rounding. If this is most of the latency, the backlog is inbound.
	InboundP50Ms float64 `json:"inbound_leg_p50_ms,omitempty"`
	InboundP99Ms float64 `json:"inbound_leg_p99_ms,omitempty"`
	InfoFrac     float64 `json:"info_fraction,omitempty"` // updates that carried EntityInfo
	// Scheduling lag of a 5 ms timer in the generator: when the machine stalls the generator
	// and the gateway together (loopback), this is where it shows.
	LagP999Ms float64 `json:"sched_lag_p999_ms"`
	LagMaxMs  float64 `json:"sched_lag_max_ms"`
	// Seconds into the window that held deliveries over 250 ms: [second, count, max lag ms].
	TailSeconds [][3]float64 `json:"tail_seconds,omitempty"`

	Stalled           int     `json:"stalled,omitempty"`
	HealthyP99Ms      float64 `json:"healthy_p99_ms,omitempty"`
	StalledClosed     int64   `json:"stalled_closed,omitempty"`
	StalledCloseS     float64 `json:"stalled_close_s,omitempty"`
	StalledBytesQueue int64   `json:"stalled_bytes_unread,omitempty"`

	StormDropped   int64   `json:"storm_dropped,omitempty"`
	StormReturned  int64   `json:"storm_returned,omitempty"`
	StormAllLiveS  float64 `json:"storm_all_live_s,omitempty"`
	StormP50LiveS  float64 `json:"storm_p50_live_s,omitempty"`
	StormDialFails int64   `json:"storm_dial_failures,omitempty"`

	GatewayRSSBeforeMB float64            `json:"gateway_rss_before_mb,omitempty"`
	GatewayRSSMB       float64            `json:"gateway_rss_mb,omitempty"`
	FootprintBeforeMB  float64            `json:"gateway_footprint_before_mb,omitempty"`
	FootprintMB        float64            `json:"gateway_footprint_mb,omitempty"`
	KBPerConn          float64            `json:"kb_per_conn,omitempty"` // from the footprint when known, else resident
	HeapKBPerConn      float64            `json:"heap_kb_per_conn,omitempty"`
	GatewayCPUPct      float64            `json:"gateway_cpu_pct,omitempty"`
	LoadgenCPUPct      float64            `json:"loadgen_cpu_pct,omitempty"`
	Metrics            map[string]float64 `json:"gateway_metrics,omitempty"`
}

var (
	urls       = flag.String("url", "http://127.0.0.1:8080", "gateway base URL(s), comma-separated; client i connects to node i mod n, so friend groups span nodes")
	base2      = flag.String("url2", "", "second gateway node (same as a second -url entry)")
	clients    = flag.Int("clients", 200, "simulated drivers")
	group      = flag.Int("group", 10, "friends per group (everyone in a group is friends with everyone else); 1 for no friends")
	hz         = flag.Float64("hz", 1, "location updates per second per driver; 0 for idle connections")
	ping       = flag.Duration("ping", 25*time.Second, "heartbeat Ping interval (plan 3.x: 25 s when stationary); 0 for none")
	duration   = flag.Duration("duration", 20*time.Second, "measurement window")
	warmup     = flag.Duration("warmup", 3*time.Second, "time after the last connection before measuring")
	secret     = flag.String("secret", os.Getenv("WAYPOINTS_BENCH_SECRET"), "HS256 secret the gateway accepts with -bench")
	scenario   = flag.String("scenario", "", "label for the results")
	label      = flag.String("label", "", "machine label, e.g. loopback")
	out        = flag.String("out", "", "append the result as one JSON line to this file")
	dialConc   = flag.Int("dial-conc", 128, "concurrent dials while ramping (the listen backlog is 128 on macOS)")
	srcIPs     = flag.String("src", "", "comma-separated local source addresses (default: let the kernel choose)")
	portRange  = flag.String("ports", "", "explicit local port range lo-hi, e.g. 10000-60000 (default: ephemeral)")
	stall      = flag.Float64("stall", 0, "fraction of clients that stop reading when measurement starts")
	stallBuf   = flag.Int("stall-rcvbuf", 0, "SO_RCVBUF for stalled clients' sockets (0 = default)")
	storm      = flag.Bool("storm", false, "drop every connection a quarter into the window; each returns after a uniform delay in -storm-spread")
	stormSprd  = flag.Duration("storm-spread", 10*time.Second, "reconnect spread for -storm")
	metricsURL = flag.String("metrics", "", "gateway /metrics URL(s), comma-separated, scraped after the run")
	pids       = flag.String("pid", "", "gateway pid(s), comma-separated, for resident memory and CPU")
	cpuprof    = flag.String("cpuprofile", "", "write the load generator's CPU profile here")
	pprofAddr  = flag.String("pprof", "", "serve the generator's /debug/pprof on this address")
	idOffset   = flag.Int("id-offset", 0, "first driver number, so several generator processes can share one node (single node only)")
	seedConc   = flag.Int("seed-conc", 16, "concurrent seeding requests")
)

func main() {
	flag.Parse()
	if *secret == "" {
		log.Fatal("loadgen: -secret or WAYPOINTS_BENCH_SECRET is required")
	}
	if *pprofAddr != "" {
		go func() { log.Println(http.ListenAndServe(*pprofAddr, nil)) }()
	}
	bases := split(*urls)
	if *base2 != "" {
		bases = append(bases, *base2)
	}
	n := *clients
	if *group < 1 {
		*group = 1
	}

	// Each node keeps its own in-memory store in bench mode, so every node gets the seed.
	ids := make([]string, n)
	for i := range ids {
		ids[i] = fmt.Sprintf("00000000-0000-4000-8000-%012d", *idOffset+i+1)
	}
	uids := seed(bases, ids)
	// node of each publisher uid, to split same-node from cross-node latency
	nodeOf := make(map[uint64]int, n)
	for i, u := range uids {
		nodeOf[u] = i % len(bases)
	}

	dialer := newDialer()
	var (
		stats                  = &counters{}
		measureFrom, measureTo atomic.Pointer[time.Time]
	)
	never := time.Now().Add(24 * time.Hour)
	measureFrom.Store(&never)
	measureTo.Store(&never)

	// RSS before any connection: the base for memory per connection.
	pidList := split(*pids)
	rssBefore, fpBefore := rssMB(pidList), footprintMB(pidList)
	heapBefore := scrape(split(*metricsURL))["go_memstats_heap_alloc_bytes"]

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cl := make([]*client, n)
	nStall := int(math.Round(*stall * float64(n)))
	for i := range cl {
		cl[i] = &client{i: i, id: ids[i], url: wsURL(bases[i%len(bases)]), stats: stats, dialer: dialer,
			from: &measureFrom, to: &measureTo, nodeOf: nodeOf, node: i % len(bases)}
		if nStall > 0 {
			stride := max(1, n/nStall)
			cl[i].stalled = i%stride == 0 && i/stride < nStall
		}
	}

	// Ramp with bounded concurrency so the listen backlog never overflows (an overflowed
	// backlog turns into SYN retransmits 1 s and 3 s later, which is a connect-time artefact).
	start := time.Now()
	sem := make(chan struct{}, *dialConc)
	var ready sync.WaitGroup
	for _, c := range cl {
		ready.Add(1)
		sem <- struct{}{}
		go func() {
			c.ok = c.connect(ctx)
			<-sem
			ready.Done()
		}()
	}
	ready.Wait()
	connectS := time.Since(start).Seconds()
	var connected atomic.Int64
	for _, c := range cl {
		if c.ok {
			connected.Add(1)
		}
	}
	log.Printf("loadgen: %d/%d connected in %.1fs", connected.Load(), n, connectS)

	var prof *os.File
	if *cpuprof != "" {
		prof, _ = os.Create(*cpuprof)
		_ = pprof.StartCPUProfile(prof)
	}

	var wg sync.WaitGroup
	for _, c := range cl {
		if c.ok {
			wg.Add(1)
			go func() { defer wg.Done(); c.run(ctx) }()
		}
	}

	time.Sleep(*warmup)
	from := time.Now()
	to := from.Add(*duration)
	measureFrom.Store(&from)
	measureTo.Store(&to)
	cpu0, lcpu0 := cpuSeconds(pidList), selfCPU()
	lagDone := make(chan struct{})
	var lags []float32
	lagBySec := map[int]float64{}
	go func() {
		defer close(lagDone)
		for t := time.Now(); t.Before(to); t = time.Now() {
			time.Sleep(5 * time.Millisecond)
			l := float64(time.Since(t)-5*time.Millisecond) / 1e6
			lags = append(lags, float32(l))
			sec := int(t.Sub(from) / time.Second)
			lagBySec[sec] = max(lagBySec[sec], l)
		}
	}()

	// Stalled subscribers: watch the gateways' connection gauge fall by the stalled count.
	var stalledClosed atomic.Int64
	var stalledCloseAt atomic.Int64
	stalledN := 0
	for _, c := range cl {
		if c.ok && c.stalled {
			stalledN++
		}
	}
	if stalledN > 0 && *metricsURL != "" {
		go func() {
			base := scrape(split(*metricsURL))["ws_connections"]
			for time.Now().Before(to) {
				time.Sleep(100 * time.Millisecond)
				now, ok := scrape(split(*metricsURL))["ws_connections"]
				if !ok {
					continue // a node did not answer; do not read that as every connection gone
				}
				gone := min(int64(base-now), int64(stalledN))
				if gone > stalledClosed.Load() {
					stalledClosed.Store(gone)
					stalledCloseAt.Store(time.Since(from).Milliseconds())
				}
			}
		}()
	}

	var stormAt time.Time
	if *storm {
		time.Sleep(*duration / 4)
		stormAt = time.Now()
		for _, c := range cl {
			if c.ok {
				c.drop(stormAt)
			}
		}
	}

	time.Sleep(time.Until(to))
	<-lagDone
	cpu1, lcpu1 := cpuSeconds(pidList), selfCPU()
	gwMetrics := scrape(split(*metricsURL))
	rssAfter, fpAfter := rssMB(pidList), footprintMB(pidList)
	cancel()
	wg.Wait()
	if prof != nil {
		pprof.StopCPUProfile()
		prof.Close()
	}

	// Merge per-client histograms.
	var all, raw, healthy, cross, inbound []float32
	var first, withInfo, frames int64
	for _, c := range cl {
		cross = append(cross, c.latCross...)
		inbound = append(inbound, c.inbound...)
		withInfo += c.withInfo
		frames += c.frames
		all = append(all, c.lat...)
		raw = append(raw, c.lat...)
		raw = append(raw, c.firstLat...)
		first += int64(len(c.firstLat))
		if !c.stalled {
			healthy = append(healthy, c.lat...)
		}
	}
	tail := map[int]int{}
	for _, c := range cl {
		for _, s := range c.tailAt {
			tail[s]++
		}
	}
	slices.Sort(all)
	slices.Sort(lags)
	slices.Sort(cross)
	slices.Sort(inbound)
	slices.Sort(raw)
	slices.Sort(healthy)

	secs := duration.Seconds()
	r := result{Scenario: *scenario, Label: *label, Clients: n, Connected: connected.Load(), Group: *group, Hz: *hz,
		TickMs: int(stats.tickMs.Load()), Nodes: len(bases), Seconds: secs, ConnectS: round(connectS, 2),
		Published: stats.published.Load(), Deliveries: stats.deliveries.Load(),
		DeliveriesSec: float64(stats.deliveries.Load()) / secs,
		P50Ms:         pct(all, 0.5), P90Ms: pct(all, 0.9), P99Ms: pct(all, 0.99), P999Ms: pct(all, 0.999), MaxMs: pct(all, 1),
		FirstExcluded: first, RawP999Ms: pct(raw, 0.999), RawMaxMs: pct(raw, 1), Errors: stats.errs.Load(),
		LagP999Ms: pct(lags, 0.999), LagMaxMs: pct(lags, 1),
		GatewayRSSBeforeMB: rssBefore, GatewayRSSMB: rssAfter, FootprintBeforeMB: fpBefore, FootprintMB: fpAfter,
		Metrics: gwMetrics}
	for sec := 0; sec <= int(secs); sec++ {
		if tail[sec] > 0 {
			r.TailSeconds = append(r.TailSeconds, [3]float64{float64(sec), float64(tail[sec]), round(lagBySec[sec], 1)})
		}
	}
	if len(bases) > 1 {
		r.CrossP50Ms, r.CrossP99Ms, r.CrossP999Ms = pct(cross, 0.5), pct(cross, 0.99), pct(cross, 0.999)
	}
	r.InboundP50Ms, r.InboundP99Ms = pct(inbound, 0.5), pct(inbound, 0.99)
	if frames > 0 {
		r.UpdatesPerFrame = round(float64(r.Deliveries)/float64(frames), 2)
	}
	if r.Deliveries > 0 {
		r.InfoFrac = round(float64(withInfo)/float64(r.Deliveries), 4)
		r.BytesPerDeliv = round(float64(stats.bytesIn.Load())/float64(r.Deliveries), 1)
	}
	if nc := float64(connected.Load()); nc > 0 {
		if fpAfter > 0 {
			r.KBPerConn = round((fpAfter-fpBefore)*1024/nc, 1)
		} else if rssAfter > 0 {
			r.KBPerConn = round((rssAfter-rssBefore)*1024/nc, 1)
		}
		if h := gwMetrics["go_memstats_heap_alloc_bytes"]; h > 0 {
			r.HeapKBPerConn = round((h-heapBefore)/1024/nc, 1)
		}
	}
	if cpu0 >= 0 && cpu1 >= 0 {
		r.GatewayCPUPct = round((cpu1-cpu0)/secs*100, 0)
	}
	r.LoadgenCPUPct = round((lcpu1-lcpu0)/secs*100, 0)
	if stalledN > 0 {
		r.Stalled = stalledN
		r.HealthyP99Ms = pct(healthy, 0.99)
		r.StalledClosed = stalledClosed.Load()
		if r.StalledClosed > 0 {
			r.StalledCloseS = float64(stalledCloseAt.Load()) / 1000
		}
	}
	if *storm {
		var back []float64
		for _, c := range cl {
			if c.ok {
				r.StormDropped++
				if t := c.returnedAt.Load(); t > 0 {
					back = append(back, float64(t-stormAt.UnixMilli())/1000)
				}
			}
		}
		slices.Sort(back)
		r.StormReturned = int64(len(back))
		r.StormDialFails = stats.dialFails.Load()
		if len(back) > 0 {
			r.StormAllLiveS = round(back[len(back)-1], 2)
			r.StormP50LiveS = round(back[len(back)/2], 2)
		}
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

type counters struct {
	published, deliveries, bytesIn, errs, dialFails atomic.Int64
	tickMs                                          atomic.Int64
}

// client is one simulated driver. Its latency samples are local so 5,000 readers never
// contend on one lock.
type client struct {
	i          int
	id         string
	url        string
	stats      *counters
	dialer     *dialer
	from, to   *atomic.Pointer[time.Time]
	stalled    bool
	ok         bool
	conn       *websocket.Conn
	mu         sync.Mutex
	dropCh     chan time.Time
	returnedAt atomic.Int64
	lat        []float32
	firstLat   []float32
	tailAt     []int // second into the window of each delivery over 250 ms
	nodeOf     map[uint64]int
	node       int
	latCross   []float32 // the subset of lat whose publisher is on the other node
	inbound    []float32 // publish leg: latency minus the gateway's age_ds (time held after it received the update)
	withInfo   int64     // updates carrying EntityInfo
	frames     int64
}

func (c *client) inWindow(t time.Time) bool {
	return t.After(*c.from.Load()) && t.Before(*c.to.Load())
}

func (c *client) token() string {
	tok, _ := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"sub": c.id, "exp": time.Now().Add(time.Hour).Unix()}).
		SignedString([]byte(*secret))
	return tok
}

// connect dials and says hello. It returns once the Welcome has arrived.
func (c *client) connect(ctx context.Context) bool {
	rcvbuf := 0
	if c.stalled {
		rcvbuf = *stallBuf
	}
	dctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(dctx, c.url, &websocket.DialOptions{HTTPClient: c.dialer.client(rcvbuf)})
	if err != nil {
		c.stats.errs.Add(1)
		return false
	}
	ws.SetReadLimit(1 << 20)
	if send(ctx, ws, &wire.ClientFrame{Body: &wire.ClientFrame_Hello{Hello: &wire.Hello{AccessToken: c.token(), Protocol: 1, AppVersion: "loadgen"}}}) != nil {
		ws.CloseNow()
		c.stats.errs.Add(1)
		return false
	}
	for {
		_, data, err := ws.Read(dctx)
		if err != nil {
			ws.CloseNow()
			c.stats.errs.Add(1)
			return false
		}
		var f wire.ServerFrame
		if proto.Unmarshal(data, &f) == nil && f.GetWelcome() != nil {
			c.stats.tickMs.Store(int64(f.GetWelcome().TickMs))
			break
		}
	}
	c.mu.Lock()
	c.conn = ws
	c.dropCh = make(chan time.Time, 1)
	c.mu.Unlock()
	return true
}

func (c *client) drop(at time.Time) {
	c.mu.Lock()
	ch := c.dropCh
	c.mu.Unlock()
	select {
	case ch <- at:
	default:
	}
}

// run drives sessions until ctx ends: publish, read, and on a storm drop, reconnect.
func (c *client) run(ctx context.Context) {
	for {
		c.mu.Lock()
		ws, dropCh := c.conn, c.dropCh
		c.mu.Unlock()
		dropped := c.session(ctx, ws, dropCh)
		ws.CloseNow()
		if !dropped || ctx.Err() != nil {
			return
		}
		time.Sleep(time.Duration(rand.Int64N(int64(*stormSprd))))
		for ctx.Err() == nil {
			if c.connect(ctx) {
				c.returnedAt.Store(time.Now().UnixMilli())
				break
			}
			c.stats.dialFails.Add(1)
			time.Sleep(250 * time.Millisecond)
		}
		if ctx.Err() != nil {
			return
		}
	}
}

// session returns true when it ended because of a storm drop.
func (c *client) session(ctx context.Context, ws *websocket.Conn, dropCh chan time.Time) bool {
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	seen := map[uint64]struct{}{}
	go c.publish(sctx, ws)
	readErr := make(chan struct{})
	go func() {
		defer close(readErr)
		for {
			if c.stalled && time.Now().After(*c.from.Load()) {
				<-sctx.Done()
				return
			}
			_, data, err := ws.Read(sctx)
			if err != nil {
				return
			}
			c.onFrame(data, seen)
		}
	}()
	select {
	case <-dropCh:
		cancel()
		<-readErr
		return true
	case <-readErr:
		return false
	case <-ctx.Done():
		<-readErr
		return false
	}
}

func (c *client) onFrame(data []byte, seen map[uint64]struct{}) {
	var f wire.ServerFrame
	if proto.Unmarshal(data, &f) != nil {
		return
	}
	b := f.GetBatch()
	if b == nil {
		return
	}
	now := time.Now()
	nowUs := float64(now.UnixMicro())
	in := c.inWindow(now)
	for _, u := range b.Updates {
		_, again := seen[u.Uid]
		seen[u.Uid] = struct{}{}
		if !in || u.OriginMs == 0 {
			continue
		}
		ms := float32((nowUs - float64(u.OriginMs)*1000) / 1000)
		if again {
			c.lat = append(c.lat, ms)
			c.inbound = append(c.inbound, ms-float32(u.AgeDs)*100)
			if c.nodeOf[u.Uid] != c.node {
				c.latCross = append(c.latCross, ms)
			}
			if u.Info != nil {
				c.withInfo++
			}
			if ms > 250 {
				c.tailAt = append(c.tailAt, int(now.Sub(*c.from.Load())/time.Second))
			}
		} else {
			c.firstLat = append(c.firstLat, ms)
		}
	}
	if in {
		c.frames++
		c.stats.bytesIn.Add(int64(len(data)))
		c.stats.deliveries.Add(int64(len(b.Updates)))
	}
}

// publish sends on a fixed schedule; the timestamp is the scheduled tick, not the send, so a
// stalled generator cannot hide delay (plan 8.2).
func (c *client) publish(ctx context.Context, ws *websocket.Conn) {
	var loc <-chan time.Time
	if *hz > 0 {
		// Random phase, so publishers do not fire in lockstep.
		select {
		case <-time.After(time.Duration(rand.Float64() * float64(time.Second) / *hz)):
		case <-ctx.Done():
			return
		}
		t := time.NewTicker(time.Duration(float64(time.Second) / *hz))
		defer t.Stop()
		loc = t.C
	}
	var hb <-chan time.Time
	if *ping > 0 {
		t := time.NewTicker(*ping)
		defer t.Stop()
		hb = t.C
	}
	lat0 := 39.9 + float64((*idOffset+c.i) / *group)*0.05
	lng0 := -75.1
	a := rand.Float64() * 2 * math.Pi
	for {
		var f *wire.ClientFrame
		select {
		case <-ctx.Done():
			return
		case now := <-hb:
			f = &wire.ClientFrame{Body: &wire.ClientFrame_Ping{Ping: &wire.Ping{ClientMs: uint64(now.UnixMilli())}}}
		case sched := <-loc:
			// Groups drive around different points so cells do not overlap across groups.
			a += 0.01
			f = &wire.ClientFrame{Body: &wire.ClientFrame_Location{Location: &wire.LocationUpdate{
				LatE7: int32((lat0 + 0.01*math.Sin(a)) * 1e7), LngE7: int32((lng0 + 0.01*math.Cos(a)) * 1e7),
				HeadingDeg: 90, SpeedCms: 1500, AccuracyM: 5, ClientMs: uint64(sched.UnixMilli()),
			}}}
			if c.inWindow(sched) {
				c.stats.published.Add(1)
			}
		}
		wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		err := send(wctx, ws, f)
		cancel()
		if err != nil {
			return
		}
	}
}

func send(ctx context.Context, ws *websocket.Conn, f *wire.ClientFrame) error {
	b, _ := proto.Marshal(f)
	return ws.Write(ctx, websocket.MessageBinary, b)
}

// dialer hands out explicit local addresses when -src or -ports is set.
type dialer struct {
	ips    []net.IP
	lo, hi int
	next   atomic.Int64
	plain  *http.Client
	small  map[int]*http.Client
	mu     sync.Mutex
}

func newDialer() *dialer {
	d := &dialer{small: map[int]*http.Client{}}
	for _, s := range split(*srcIPs) {
		d.ips = append(d.ips, net.ParseIP(s))
	}
	if *portRange != "" {
		lo, hi, _ := strings.Cut(*portRange, "-")
		d.lo, _ = strconv.Atoi(lo)
		d.hi, _ = strconv.Atoi(hi)
	}
	d.plain = d.build(0)
	return d
}

func (d *dialer) client(rcvbuf int) *http.Client {
	if rcvbuf == 0 {
		return d.plain
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.small[rcvbuf] == nil {
		d.small[rcvbuf] = d.build(rcvbuf)
	}
	return d.small[rcvbuf]
}

func (d *dialer) build(rcvbuf int) *http.Client {
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		for attempt := 0; ; attempt++ {
			nd := net.Dialer{Control: func(_, _ string, rc syscall.RawConn) error {
				return rc.Control(func(fd uintptr) {
					_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
					if rcvbuf > 0 {
						_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF, rcvbuf)
					}
				})
			}}
			if len(d.ips) > 0 || d.hi > 0 {
				k := d.next.Add(1)
				la := &net.TCPAddr{}
				if len(d.ips) > 0 {
					la.IP = d.ips[int(k)%len(d.ips)]
					k /= int64(len(d.ips))
				}
				if d.hi > 0 {
					la.Port = d.lo + int(k)%(d.hi-d.lo+1)
				}
				nd.LocalAddr = la
			}
			c, err := nd.DialContext(ctx, network, addr)
			if err == nil || attempt > 50 || ctx.Err() != nil || !errors.Is(err, syscall.EADDRINUSE) && !errors.Is(err, syscall.EADDRNOTAVAIL) {
				return c, err
			}
		}
	}
	return &http.Client{Transport: &http.Transport{DialContext: dial, MaxIdleConnsPerHost: -1, DisableKeepAlives: true}}
}

// seed creates the profiles and friendships on every node and returns each driver's numeric
// uid. Profiles go to each node one at a time and in order: the in-memory store hands out uids
// by arrival, and the bus carries uids, so every node must give a driver the same one.
func seed(bases []string, ids []string) []uint64 {
	hc := &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: *seedConc}}
	uids := make([][]uint64, len(bases))
	var wg sync.WaitGroup
	for n, b := range bases {
		uids[n] = make([]uint64, len(ids))
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i, id := range ids {
				var r struct{ UID uint64 }
				_ = json.Unmarshal(post(hc, b+"/dev/profile", map[string]any{"user_id": id, "display_name": fmt.Sprintf("Driver %d", i+1), "marker_icon": "coupe"}), &r)
				uids[n][i] = r.UID
			}
		}()
	}
	wg.Wait()
	for n := 1; n < len(bases); n++ {
		if !slices.Equal(uids[0], uids[n]) {
			log.Fatalf("loadgen: node %s gave different uids than %s; start every node fresh", bases[n], bases[0])
		}
	}

	type pair struct{ a, b string }
	jobs := make(chan pair, 1024)
	for range *seedConc {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				for _, b := range bases {
					post(hc, b+"/dev/friends", map[string]string{"a": j.a, "b": j.b})
				}
			}
		}()
	}
	for g := 0; g < len(ids); g += *group {
		end := min(g+*group, len(ids))
		for a := g; a < end; a++ {
			for b := a + 1; b < end; b++ {
				jobs <- pair{ids[a], ids[b]}
			}
		}
	}
	close(jobs)
	wg.Wait()
	return uids[0]
}

func post(hc *http.Client, url string, body any) []byte {
	b, _ := json.Marshal(body)
	resp, err := hc.Post(url, "application/json", bytes.NewReader(b))
	if err != nil {
		log.Fatalf("loadgen: %s: %v", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		log.Fatalf("loadgen: %s: %s (is the gateway running with WAYPOINTS_ENV=bench and no DATABASE_URL?)", url, resp.Status)
	}
	out, _ := io.ReadAll(resp.Body)
	return out
}

// scrape sums each unlabelled-or-labelled series by metric name across nodes.
func scrape(urls []string) map[string]float64 {
	if len(urls) == 0 {
		return nil
	}
	m := map[string]float64{}
	keep := []string{"ws_connections", "go_goroutines", "go_memstats_heap_alloc_bytes", "go_memstats_sys_bytes",
		"go_gc_cycles_total", "go_gc_pause_seconds_total", "hub_publish_dropped_total", "hub_deliveries_total",
		"hub_publishes_total", "ws_slow_consumer_closed_total", "ws_location_rate_dropped_total", "ws_bytes_out_total"}
	for _, u := range urls {
		resp, err := http.Get(u)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			line := sc.Text()
			if strings.HasPrefix(line, "#") {
				continue
			}
			name, val, ok := strings.Cut(line, " ")
			if !ok {
				continue
			}
			if i := strings.IndexByte(name, '{'); i >= 0 {
				name = name[:i]
			}
			if !slices.Contains(keep, name) {
				continue
			}
			if f, err := strconv.ParseFloat(strings.TrimSpace(val), 64); err == nil {
				m[name] += f
			}
		}
		resp.Body.Close()
	}
	return m
}

// rssMB sums resident memory of the given pids, from ps.
func rssMB(pids []string) float64 {
	if len(pids) == 0 {
		return 0
	}
	total := 0.0
	for _, p := range pids {
		b, err := exec.Command("ps", "-o", "rss=", "-p", p).Output()
		if err != nil {
			return 0
		}
		kb, _ := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
		total += kb / 1024
	}
	return round(total, 1)
}

// footprintMB sums phys_footprint (resident plus compressed, what macOS charges the process)
// from footprint(1); 0 if unavailable. Under memory pressure ps rss undercounts.
func footprintMB(pids []string) float64 {
	if len(pids) == 0 {
		return 0
	}
	total := 0.0
	for _, p := range pids {
		b, err := exec.Command("footprint", p).Output()
		if err != nil {
			return 0
		}
		found := false
		for _, line := range strings.Split(string(b), "\n") {
			v, ok := strings.CutPrefix(strings.TrimSpace(line), "phys_footprint:")
			if !ok {
				continue
			}
			f := strings.Fields(v)
			if len(f) < 2 {
				continue
			}
			x, _ := strconv.ParseFloat(f[0], 64)
			switch f[1] {
			case "KB":
				x /= 1024
			case "GB":
				x *= 1024
			case "B":
				x /= 1 << 20
			}
			total += x
			found = true
			break
		}
		if !found {
			return 0
		}
	}
	return round(total, 1)
}

// cpuSeconds sums user+system CPU time of the given pids, from ps; -1 if unknown.
func cpuSeconds(pids []string) float64 {
	if len(pids) == 0 {
		return -1
	}
	total := 0.0
	for _, p := range pids {
		b, err := exec.Command("ps", "-o", "time=", "-p", p).Output()
		if err != nil {
			return -1
		}
		total += parseClock(strings.TrimSpace(string(b)))
	}
	return total
}

func parseClock(s string) float64 { // [[hh:]mm:]ss.ss
	t := 0.0
	for _, part := range strings.Split(s, ":") {
		f, _ := strconv.ParseFloat(part, 64)
		t = t*60 + f
	}
	return t
}

func selfCPU() float64 {
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return float64(ru.Utime.Sec+ru.Stime.Sec) + float64(ru.Utime.Usec+ru.Stime.Usec)/1e6
}

func pct(s []float32, p float64) float64 {
	if len(s) == 0 {
		return 0
	}
	return round(float64(s[min(len(s)-1, int(p*float64(len(s))))]), 1)
}

func round(f float64, d int) float64 {
	m := math.Pow(10, float64(d))
	return math.Round(f*m) / m
}

func split(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func wsURL(base string) string { return strings.Replace(base, "http", "ws", 1) + "/v1/rt" }
