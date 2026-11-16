// Package ws serves /v1/rt: one WebSocket per client, a reader goroutine that
// decodes, rate-limits, resolves privacy and publishes, and a writer goroutine
// that drains the connection's outbox once per tick (sections 6 and 7.2).
package ws

import (
	"context"
	"errors"
	"flag"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/bus"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/hub"
	"waypoints/server/internal/metrics"
	"waypoints/server/internal/privacy"
	"waypoints/server/internal/store"
	"waypoints/server/internal/wire"
)

var tickFlag = flag.Duration("tick", 100*time.Millisecond, "writer flush interval; 0 flushes on every change")

// Protocol is the wire protocol version this gateway speaks.
const Protocol = 1

const (
	helloTimeout   = 10 * time.Second
	writeTimeout   = 5 * time.Second
	pingEvery      = 2 * time.Second
	pongTimeout    = 3 * time.Second
	minInterval    = 400 * time.Millisecond
	approxInterval = 15 * time.Second
	maxBadFrames   = 20
	maxFrameBytes  = 16 << 10
	// maxConnsPerUser bounds simultaneous sockets per account; each holds an
	// outbox, subscriptions, and two goroutines.
	maxConnsPerUser = 8

	closeSlowConsumer websocket.StatusCode = 4008
	closeBadFrame     websocket.StatusCode = 4002
	closeUnauthorized websocket.StatusCode = 4001
)

var errBadFrame = errors.New("bad frame")

// KindConvoy is the topic family for convoy deliveries, which bypass the hub:
// convoy members always get precise positions (section 2.5).
const KindConvoy hub.Kind = 100

// ConvoyAuthority answers whether a user may receive a convoy's positions.
// Package convoy installs one with SetConvoys.
type ConvoyAuthority interface {
	IsMember(convoyID string, uid uint64) bool
	Snapshot(convoyID string) *wire.ConvoyState
	Leave(convoyID string, uid uint64)
}

// MapEventSubject carries encoded MapEventEnvelope payloads on the bus.
const MapEventSubject = "mapev"

// Server owns every live connection on this node.
type Server struct {
	a        *app.App
	hub      *hub.Hub
	priv     *privacy.Service
	store    *store.Store
	auth     *auth.Verifier
	bus      bus.Bus
	multi    bool // the bus reaches other nodes (NATS), so convoy fan-out publishes to it
	tick     time.Duration
	bench    bool
	maxConns int
	ipLim    *app.Limiter
	m        serverMetrics
	mu       sync.RWMutex
	conns    map[*conn]struct{}
	byUID    map[uint64]map[*conn]struct{}
	convoys  map[string]map[*conn]struct{}
	cauth    ConvoyAuthority
}

type serverMetrics struct {
	conns      *metrics.Gauge
	frames     *metrics.Counter
	badFrames  *metrics.Counter
	rateDrops  *metrics.Counter
	frameDrops *metrics.Counter
	slowClosed *metrics.Counter
	flush      *metrics.Histogram
	bytesOut   *metrics.Counter
}

// Register mounts /v1/rt and provides *Server.
func Register(a *app.App) {
	s := &Server{
		a:        a,
		hub:      app.MustLookup[*hub.Hub](a),
		priv:     app.MustLookup[*privacy.Service](a),
		store:    app.MustLookup[*store.Store](a),
		auth:     app.MustLookup[*auth.Verifier](a),
		bus:      bus.From(a),
		multi:    !bus.From(a).Local(),
		tick:     *tickFlag,
		bench:    auth.Bench(),
		maxConns: a.Config.MaxConns,
		ipLim:    app.NewLimiter(300, time.Minute), // upgrade attempts per client IP
		conns:    map[*conn]struct{}{},
		byUID:    map[uint64]map[*conn]struct{}{},
		convoys:  map[string]map[*conn]struct{}{},
	}
	reg := a.Metrics
	s.m = serverMetrics{
		conns:      reg.Gauge("ws_connections", "Open realtime connections.", nil),
		frames:     reg.Counter("ws_frames_in_total", "Client frames decoded.", nil),
		badFrames:  reg.Counter("ws_bad_frames_total", "Client frames that failed to decode.", nil),
		rateDrops:  reg.Counter("ws_location_rate_dropped_total", "Location updates dropped by the 400 ms limit.", nil),
		frameDrops: reg.Counter("ws_frame_rate_dropped_total", "Frames dropped by per-type rate limits.", nil),
		slowClosed: reg.Counter("ws_slow_consumer_closed_total", "Connections closed with 4008.", nil),
		flush:      reg.Histogram("ws_flush_seconds", "Time to encode and write one batch.", nil, nil),
		bytesOut:   reg.Counter("ws_bytes_out_total", "Bytes written to clients.", nil),
	}
	reg.GaugeFunc("ws_outbox_depth", "Pending entries across all outboxes.", nil, func() float64 {
		s.mu.RLock()
		defer s.mu.RUnlock()
		n := 0
		for c := range s.conns {
			if c.out != nil {
				n += c.out.depth()
			}
		}
		return float64(n)
	})
	_, _ = s.bus.Subscribe(MapEventSubject, func(m bus.Msg) { s.fanMapEvent(m.Data) })
	a.Mux.HandleFunc("GET /v1/rt", s.serve)
	a.Go("ws-suspensions", s.sweepSuspended)
	a.Go("ws-relations", s.sweepRelations)
	a.OnStop("ws", func(ctx context.Context) error { s.closeAll(ctx); return nil })
	app.Provide(a, s)
}

// SetConvoys installs the convoy membership authority.
func (s *Server) SetConvoys(c ConvoyAuthority) {
	s.mu.Lock()
	s.cauth = c
	s.mu.Unlock()
}

// SendToUID enqueues a frame on the reliable lane of every connection of uid.
func (s *Server) SendToUID(uid uint64, f *wire.ServerFrame) {
	b, err := proto.Marshal(f)
	if err != nil {
		return
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for c := range s.byUID[uid] {
		c.out.Enqueue(b)
	}
}

// LastFix returns the newest position this node has for a user, for check-ins. It never
// leaves the gateway.
func (s *Server) LastFix(userID string) (lat, lng int32, ok bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for c := range s.conns {
		if c.userID != userID {
			continue
		}
		c.mu.Lock()
		lat, lng, ok = c.lastLat, c.lastLng, c.hasFix
		c.mu.Unlock()
		if ok {
			return
		}
	}
	return 0, 0, false
}

// DropFromConvoy detaches every connection of uid from convoyID (leave or end).
func (s *Server) DropFromConvoy(convoyID string, uid uint64) {
	s.mu.RLock()
	var cs []*conn
	for c := range s.byUID[uid] {
		cs = append(cs, c)
	}
	s.mu.RUnlock()
	for _, c := range cs {
		c.leaveConvoy(convoyID)
	}
}

// PublishMapEvent sends a map event to every connection whose viewport holds
// the point, on every node.
func (s *Server) PublishMapEvent(ev *wire.MapEvent) {
	b, err := proto.Marshal(&wire.ServerFrame{Body: &wire.ServerFrame_MapEvent{MapEvent: ev}})
	if err != nil {
		return
	}
	_ = s.bus.Publish(MapEventSubject, b)
}

func (s *Server) fanMapEvent(frame []byte) {
	var f wire.ServerFrame
	if proto.Unmarshal(frame, &f) != nil {
		return
	}
	ev := f.GetMapEvent()
	if ev == nil {
		return
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for c := range s.conns {
		if c.viewportHolds(ev.LatE7, ev.LngE7) {
			c.out.Enqueue(frame)
		}
	}
}

func (s *Server) closeAll(ctx context.Context) {
	s.mu.RLock()
	var cs []*conn
	for c := range s.conns {
		cs = append(cs, c)
	}
	s.mu.RUnlock()
	var wg sync.WaitGroup
	for _, c := range cs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.closeWith(wire.Error_SHUTTING_DOWN, "shutting down", websocket.StatusGoingAway)
		}()
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

func (s *Server) add(c *conn) {
	s.mu.Lock()
	s.conns[c] = struct{}{}
	if s.byUID[c.uid] == nil {
		s.byUID[c.uid] = map[*conn]struct{}{}
	}
	s.byUID[c.uid][c] = struct{}{}
	s.mu.Unlock()
	s.m.conns.Inc()
}

func (s *Server) remove(c *conn) {
	s.mu.Lock()
	delete(s.conns, c)
	if m := s.byUID[c.uid]; m != nil {
		delete(m, c)
		if len(m) == 0 {
			delete(s.byUID, c.uid)
		}
	}
	for id, m := range s.convoys {
		delete(m, c)
		if len(m) == 0 {
			delete(s.convoys, id)
		}
	}
	s.mu.Unlock()
	s.m.conns.Dec()
}

func (s *Server) serve(w http.ResponseWriter, r *http.Request) {
	if s.a.Draining() {
		http.Error(w, "draining", http.StatusServiceUnavailable)
		return
	}
	// Pre-auth limits: each attempt costs a hello timeout and two goroutines,
	// so cap attempts per IP and total open connections before upgrading.
	// Bench skips them: the load generators dial thousands of sockets from
	// loopback by design.
	if !s.bench {
		if !s.ipLim.Allow(app.ClientIP(r)) {
			http.Error(w, "rate limited", http.StatusTooManyRequests)
			return
		}
		s.mu.RLock()
		n := len(s.conns)
		s.mu.RUnlock()
		if s.maxConns > 0 && n >= s.maxConns {
			http.Error(w, "too many connections", http.StatusServiceUnavailable)
			return
		}
	}
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode:    websocket.CompressionDisabled,
		InsecureSkipVerify: true, // native clients send no Origin
	})
	if err != nil {
		return
	}
	defer ws.CloseNow() // the socket is hijacked: nothing else closes it when the client just drops
	ws.SetReadLimit(maxFrameBytes)
	c := &conn{s: s, ws: ws, log: s.a.Log.With("pkg", "ws"), rels: map[uint64]wire.Relation{}}
	// The request context is cancelled the moment shutdown begins, which would drop the
	// socket before closeAll can say why.
	c.run(context.WithoutCancel(r.Context()))
}

// frameBucket is a per-connection token bucket for one client frame family.
// Only the reader goroutine touches it.
type frameBucket struct {
	tokens float64
	rate   float64 // tokens per second
	burst  float64
	last   time.Time
}

func (b *frameBucket) allow(now time.Time) bool {
	b.tokens = min(b.burst, b.tokens+b.rate*now.Sub(b.last).Seconds())
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// initGates sizes the per-connection frame limits. The values are generous
// for the real client (viewport changes on map moves, one ping per 25 s,
// convoy joins are rare, tokens refresh about hourly) and only stop floods.
func (c *conn) initGates() {
	c.any = frameBucket{tokens: 200, rate: 100, burst: 200}
	c.viewport = frameBucket{tokens: 15, rate: 5, burst: 15}
	c.ping = frameBucket{tokens: 10, rate: 5, burst: 10}
	c.convoyGate = frameBucket{tokens: 2, rate: 0.5, burst: 2}
	c.zoneGate = frameBucket{tokens: 3, rate: 0.2, burst: 3}
	c.refresh = frameBucket{tokens: 2, rate: 0.2, burst: 2}
}

// conn is one client.
type conn struct {
	s   *Server
	ws  *websocket.Conn
	log interface {
		Debug(string, ...any)
		Info(string, ...any)
	}

	userID string
	uid    uint64
	expiry atomic.Int64 // token expiry, Unix ms; the reader refreshes it, the pinger enforces it
	info   *hub.Info
	out    *Outbox

	// pubMu serialises a policy change with a location publish, so a cell publish
	// decided under the old policy never lands after the leave the new one sent.
	pubMu sync.Mutex

	// relMu serialises relation reloads (connect and the relations sweep) with
	// the unsubscribe at close, so a refresh can never subscribe after cleanup ran.
	relMu sync.Mutex
	rels  map[uint64]wire.Relation // u.<uid> topics subscribed; nil once closing

	mu        sync.Mutex // guards the fields below (reader goroutine and bus callbacks)
	settings  store.Settings
	zones     []geo.Zone
	policy    privacy.Policy
	hasPolicy bool
	lastLat   int32
	lastLng   int32
	hasFix    bool
	vp        geo.Rect
	hasVP     bool
	cells     map[uint64]struct{}
	aggs      map[uint64]struct{}
	convoy    string

	lastLoc    time.Time
	lastApprox time.Time
	approx     *hub.Update
	pubCell    uint64
	pubAgg     uint64
	bad        int
	badSince   time.Time

	// Frame rate gates; the reader goroutine is their only user.
	any        frameBucket
	viewport   frameBucket
	ping       frameBucket
	convoyGate frameBucket
	zoneGate   frameBucket
	refresh    frameBucket
}

func (c *conn) run(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer func() {
		// The socket is hijacked, so net/http's per-request recovery does not
		// cover this goroutine: a panic here must not take the process down.
		if rec := recover(); rec != nil {
			c.s.a.Log.Error("ws connection panicked", "panic", rec)
			cancel()
		}
	}()
	c.initGates()

	hctx, hcancel := context.WithTimeout(ctx, helloTimeout)
	f, err := c.read(hctx)
	hcancel()
	hello := f.GetHello()
	if err != nil || hello == nil {
		c.ws.Close(closeBadFrame, "expected hello")
		return
	}
	if hello.Protocol != Protocol {
		c.closeWith(wire.Error_PROTOCOL_VERSION, "unsupported protocol", closeBadFrame)
		return
	}
	lctx, lcancel := context.WithTimeout(ctx, helloTimeout)
	defer lcancel()
	claims, err := c.s.auth.Verify(lctx, hello.AccessToken)
	if errors.Is(err, auth.ErrSuspended) {
		c.closeWith(wire.Error_UNAUTHORIZED, "suspended", closeUnauthorized)
		return
	}
	if err != nil {
		c.closeWith(wire.Error_UNAUTHORIZED, "unauthorized", closeUnauthorized)
		return
	}
	c.userID = claims.UserID
	c.expiry.Store(claims.Expiry.UnixMilli())

	prof, err := c.s.store.Profile(lctx, c.userID)
	if err != nil {
		c.closeWith(wire.Error_UNAUTHORIZED, "no profile", closeUnauthorized)
		return
	}
	c.uid = prof.UID
	c.info = &hub.Info{MarkerIcon: prof.MarkerIcon, MarkerTrail: prof.MarkerTrail, PaintRGB: prof.PaintRGB,
		DisplayName: prof.DisplayName, CarLabel: prof.CarLabel}

	// Without the user's settings and blocks nothing may be published for them: defaults
	// would share more than they chose.
	settings, err := c.s.priv.Acquire(lctx, c.userID)
	if err != nil {
		c.ws.Close(websocket.StatusTryAgainLater, "store unavailable")
		return
	}
	defer c.s.priv.Release(c.userID)
	c.settings = settings
	rels, err := c.s.store.Relations(lctx, c.userID)
	if err != nil {
		c.ws.Close(websocket.StatusTryAgainLater, "store unavailable")
		return
	}

	// Bound connections per account and in total before registering.
	c.s.mu.RLock()
	perUser, total := len(c.s.byUID[c.uid]), len(c.s.conns)
	c.s.mu.RUnlock()
	if perUser >= maxConnsPerUser || (c.s.maxConns > 0 && total >= c.s.maxConns) {
		c.closeWith(wire.Error_RATE_LIMITED, "too many connections", closeBadFrame)
		return
	}

	c.out = newOutbox(c.uid, rels.Blocked, func() {
		defer func() {
			if rec := recover(); rec != nil {
				c.s.a.Log.Error("ws outbox overflow handler panicked", "panic", rec)
			}
		}()
		c.s.m.slowClosed.Inc()
		go func() {
			defer func() {
				if rec := recover(); rec != nil {
					c.s.a.Log.Error("ws slow-consumer close panicked", "panic", rec)
				}
			}()
			c.ws.Close(closeSlowConsumer, "slow consumer")
		}()
	})
	c.s.add(c)
	defer c.s.remove(c)

	welcome := &wire.ServerFrame{Body: &wire.ServerFrame_Welcome{Welcome: &wire.Welcome{
		Uid: c.uid, ServerMs: uint64(time.Now().UnixMilli()), TickMs: uint32(c.s.tick / time.Millisecond), Node: c.s.a.Config.Node,
	}}}
	c.enqueue(welcome)

	c.applyRelations(rels)
	c.updatePolicy(time.Now())

	unsubACL, _ := c.s.bus.Subscribe(privacy.ACLSubject(c.uid), func(m bus.Msg) {
		if st, ok := c.s.priv.Apply(c.userID, m.Data); ok {
			c.mu.Lock()
			c.settings = st
			c.mu.Unlock()
			c.pubMu.Lock()
			c.updatePolicy(time.Now())
			c.pubMu.Unlock()
		}
	})

	defer func() {
		if unsubACL != nil {
			unsubACL()
		}
		c.relMu.Lock()
		for uid := range c.rels {
			c.s.hub.Unsubscribe(hub.UserTopic(uid), c.out)
		}
		c.rels = nil
		c.relMu.Unlock()
		c.mu.Lock()
		cells, aggs, pubCell, pubAgg, convoy := c.cells, c.aggs, c.pubCell, c.pubAgg, c.convoy
		c.mu.Unlock()
		c.leaveConvoy(convoy)
		for h := range cells {
			c.s.hub.Unsubscribe(hub.CellTopic(h), c.out)
		}
		for h := range aggs {
			c.s.hub.Unsubscribe(hub.AggTopic(h), c.out)
		}
		if pubCell != 0 {
			c.s.hub.LeaveCell(pubCell, c.uid)
		}
		if pubAgg != 0 {
			c.s.hub.LeaveAgg(pubAgg, c.uid)
		}
		c.s.mu.RLock()
		last := len(c.s.byUID[c.uid]) <= 1
		c.s.mu.RUnlock()
		if last {
			c.s.hub.Offline(c.uid)
		}
	}()

	go c.writer(ctx, cancel)
	defer c.startPinger(ctx, cancel)()
	c.reader(ctx)
}

// startPinger closes a client that has stopped reading (PERF-4). The conflated lane never backs
// up far enough to block a write, so a stalled reader is found by a WebSocket ping it does not
// answer: at most pingEvery + pongTimeout after it stalls. A timer, not a goroutine per
// connection: an idle connection pays for one only while a ping is in flight.
func (c *conn) startPinger(ctx context.Context, cancel context.CancelFunc) (stop func() bool) {
	var t *time.Timer
	armed := make(chan struct{})
	t = time.AfterFunc(pingEvery, func() {
		// A panic in a timer goroutine would kill the process.
		defer func() {
			if rec := recover(); rec != nil {
				c.s.a.Log.Error("ws pinger panicked", "panic", rec)
			}
		}()
		<-armed
		if time.Now().UnixMilli() > c.expiry.Load() {
			c.closeWith(wire.Error_UNAUTHORIZED, "token expired", closeUnauthorized)
			return
		}
		pctx, pcancel := context.WithTimeout(ctx, pongTimeout)
		err := c.ws.Ping(pctx)
		pcancel()
		if err == nil {
			t.Reset(pingEvery)
			return
		}
		if ctx.Err() == nil {
			c.s.m.slowClosed.Inc()
			go c.ws.Close(closeSlowConsumer, "slow consumer")
			time.AfterFunc(250*time.Millisecond, cancel) // let the close frame leave, then stop waiting on the peer
		}
	})
	close(armed)
	return t.Stop
}

func (c *conn) read(ctx context.Context) (*wire.ClientFrame, error) {
	typ, data, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	if typ != websocket.MessageBinary {
		return nil, errBadFrame
	}
	var f wire.ClientFrame
	if err := proto.Unmarshal(data, &f); err != nil {
		return nil, errBadFrame
	}
	return &f, nil
}

func (c *conn) enqueue(f *wire.ServerFrame) {
	if b, err := proto.Marshal(f); err == nil {
		c.out.Enqueue(b)
	}
}

func (c *conn) sendError(code wire.Error_Code, msg string) {
	if c.out != nil {
		c.enqueue(&wire.ServerFrame{Body: &wire.ServerFrame_Error{Error: &wire.Error{Code: code, Message: msg}}})
	}
}

// closeWith writes an Error frame directly (the writer may not be running yet)
// and closes.
func (c *conn) closeWith(code wire.Error_Code, msg string, status websocket.StatusCode) {
	b, _ := proto.Marshal(&wire.ServerFrame{Body: &wire.ServerFrame_Error{Error: &wire.Error{Code: code, Message: msg}}})
	ctx, cancel := context.WithTimeout(context.Background(), writeTimeout)
	_ = c.ws.Write(ctx, websocket.MessageBinary, b)
	cancel()
	c.ws.Close(status, msg)
}

func (c *conn) reader(ctx context.Context) {
	for {
		f, err := c.read(ctx)
		if err != nil {
			if !errors.Is(err, errBadFrame) {
				return
			}
			if !c.countBad() {
				c.closeWith(wire.Error_BAD_FRAME, "too many bad frames", closeBadFrame)
				return
			}
			continue
		}
		c.s.m.frames.Inc()
		now := time.Now()
		if now.UnixMilli() > c.expiry.Load() {
			c.closeWith(wire.Error_UNAUTHORIZED, "token expired", closeUnauthorized)
			return
		}
		if !c.any.allow(now) {
			c.s.m.frameDrops.Inc()
			continue
		}
		gate := func(b *frameBucket) bool {
			if b.allow(now) {
				return true
			}
			c.s.m.frameDrops.Inc()
			return false
		}
		switch b := f.Body.(type) {
		case *wire.ClientFrame_Location:
			c.onLocation(b.Location, now)
		case *wire.ClientFrame_Viewport:
			if gate(&c.viewport) {
				c.onViewport(b.Viewport)
			}
		case *wire.ClientFrame_Ping:
			if gate(&c.ping) {
				c.enqueue(&wire.ServerFrame{Body: &wire.ServerFrame_Pong{Pong: &wire.Pong{ClientMs: b.Ping.ClientMs, ServerMs: uint64(now.UnixMilli())}}})
			}
		case *wire.ClientFrame_RefreshToken:
			if !gate(&c.refresh) {
				continue
			}
			if cl, err := c.s.auth.Verify(ctx, b.RefreshToken.AccessToken); err == nil && cl.UserID == c.userID {
				c.expiry.Store(cl.Expiry.UnixMilli())
			} else {
				c.closeWith(wire.Error_UNAUTHORIZED, "unauthorized", closeUnauthorized)
				return
			}
		case *wire.ClientFrame_HomeZones:
			if !gate(&c.zoneGate) {
				continue
			}
			zones := make([]geo.Zone, 0, 3)
			for i, z := range b.HomeZones.Zones {
				if i == 3 {
					break
				}
				r := z.RadiusM
				if r == 0 || r > 300 {
					r = 300
				}
				zones = append(zones, geo.Zone{LatE7: z.LatE7, LngE7: z.LngE7, RadiusM: r})
			}
			c.mu.Lock()
			c.zones = zones
			c.mu.Unlock()
			c.pubMu.Lock()
			c.updatePolicy(now)
			c.pubMu.Unlock()
		case *wire.ClientFrame_JoinConvoy:
			if gate(&c.convoyGate) {
				c.joinConvoy(b.JoinConvoy.ConvoyId)
			}
		case *wire.ClientFrame_LeaveConvoy:
			if !gate(&c.convoyGate) {
				continue
			}
			c.mu.Lock()
			id := c.convoy
			c.mu.Unlock()
			c.s.DropFromConvoy(id, c.uid)
			c.s.mu.RLock()
			ca := c.s.cauth
			c.s.mu.RUnlock()
			if ca != nil && id != "" {
				ca.Leave(id, c.uid)
			}
		case *wire.ClientFrame_Hello:
		default:
			if !c.countBad() {
				c.closeWith(wire.Error_BAD_FRAME, "too many bad frames", closeBadFrame)
				return
			}
		}
	}
}

func (c *conn) countBad() bool {
	c.s.m.badFrames.Inc()
	now := time.Now()
	if now.Sub(c.badSince) > time.Minute {
		c.badSince, c.bad = now, 0
	}
	c.bad++
	return c.bad < maxBadFrames
}

func (c *conn) writer(ctx context.Context, cancel context.CancelFunc) {
	defer cancel()
	defer func() {
		if rec := recover(); rec != nil {
			c.s.a.Log.Error("ws writer panicked", "panic", rec)
			cancel()
		}
	}()
	var tick <-chan time.Time
	if c.s.tick > 0 {
		t := time.NewTicker(c.s.tick)
		defer t.Stop()
		tick = t.C
	}
	write := func(b []byte) bool {
		wctx, wcancel := context.WithTimeout(ctx, writeTimeout)
		defer wcancel()
		if err := c.ws.Write(wctx, websocket.MessageBinary, b); err != nil {
			c.ws.Close(websocket.StatusPolicyViolation, "write timeout")
			return false
		}
		c.s.m.bytesOut.Add(uint64(len(b)))
		return true
	}
	flush := func() bool {
		start := time.Now()
		batch := c.out.take(start, c.s.bench)
		if batch == nil {
			return true
		}
		b, err := proto.Marshal(&wire.ServerFrame{Body: &wire.ServerFrame_Batch{Batch: batch}})
		if err != nil {
			return true
		}
		ok := write(b)
		c.s.m.flush.ObserveDuration(time.Since(start))
		return ok
	}
	for {
		select {
		case <-ctx.Done():
			return
		case b := <-c.out.reliable:
			if !write(b) {
				return
			}
		case <-tick:
			if !flush() {
				return
			}
		case <-c.out.signal:
			if tick == nil && !flush() {
				return
			}
		}
	}
}

// updatePolicy recomputes the effective policy and tells the hub on change.
func (c *conn) updatePolicy(now time.Time) {
	c.mu.Lock()
	inZone := c.hasFix && geo.InAnyZone(c.zones, c.lastLat, c.lastLng)
	p := privacy.Effective(c.settings, inZone, now)
	changed := !c.hasPolicy || p != c.policy
	c.policy, c.hasPolicy = p, true
	pubCell, pubAgg := c.pubCell, c.pubAgg
	if p.Nearby != store.Approx {
		c.pubCell, c.pubAgg = 0, 0
	}
	c.mu.Unlock()
	if !changed {
		return
	}
	c.s.hub.SetPolicy(c.uid, p)
	if p.Nearby != store.Approx {
		if pubCell != 0 {
			c.s.hub.LeaveCell(pubCell, c.uid)
		}
		if pubAgg != 0 {
			c.s.hub.LeaveAgg(pubAgg, c.uid)
		}
	}
}

// applyRelations diffs a freshly loaded relation set against the u.<uid>
// topics this connection subscribes to (PRV-13). It runs at connect and on
// every relations sweep, so a mid-session block or unfriend applies without
// reconnecting: dropped relations are unsubscribed (the shard sends gone),
// new ones get the topic's snapshot, and the outbox block set is swapped.
func (c *conn) applyRelations(r store.Relations) {
	want := make(map[uint64]wire.Relation, len(r.Friends)+len(r.Teammates))
	for _, f := range r.Friends {
		want[f] = wire.Relation_FRIEND
	}
	for _, t := range r.Teammates {
		if _, ok := want[t]; !ok {
			want[t] = wire.Relation_TEAMMATE
		}
	}
	c.relMu.Lock()
	defer c.relMu.Unlock()
	if c.rels == nil { // closing: cleanup already unsubscribed
		return
	}
	c.out.SetBlocked(r.Blocked)
	for uid, rel := range want {
		if old, ok := c.rels[uid]; !ok || old != rel {
			// Subscribe refcounts the bridge subscription; a changed relation needs
			// the old count released first or the topic is never dropped.
			if ok {
				c.s.hub.Unsubscribe(hub.UserTopic(uid), c.out)
			}
			c.s.hub.Subscribe(hub.UserTopic(uid), c.out, rel)
		}
	}
	for uid := range c.rels {
		if _, ok := want[uid]; !ok {
			c.s.hub.Unsubscribe(hub.UserTopic(uid), c.out)
		}
	}
	c.rels = want
}

func (c *conn) onLocation(l *wire.LocationUpdate, now time.Time) {
	if !geo.Valid(l.LatE7, l.LngE7) {
		c.countBad()
		return
	}
	if now.Sub(c.lastLoc) < minInterval {
		c.s.m.rateDrops.Inc()
		return
	}
	c.lastLoc = now
	c.pubMu.Lock()
	defer c.pubMu.Unlock()
	heading := l.HeadingDeg
	if heading > 360 {
		heading = 360
	}
	c.mu.Lock()
	c.lastLat, c.lastLng, c.hasFix = l.LatE7, l.LngE7, true
	convoy := c.convoy
	c.mu.Unlock()
	c.updatePolicy(now)

	c.mu.Lock()
	p := c.policy
	c.mu.Unlock()

	var origin uint64
	if c.s.bench {
		origin = l.ClientMs
	}
	precise := &hub.Update{UID: c.uid, LatE7: l.LatE7, LngE7: l.LngE7, Heading: heading, Tier: wire.Tier_PRECISE,
		At: now, OriginMs: origin, Info: c.info}

	var approx *hub.Update
	if p.AnyApprox() && (c.approx == nil || now.Sub(c.lastApprox) >= approxInterval) {
		alat, alng := geo.Approximate(l.LatE7, l.LngE7)
		approx = &hub.Update{UID: c.uid, LatE7: alat, LngE7: alng, Heading: 360, Tier: wire.Tier_APPROX,
			At: now, OriginMs: origin, Info: c.info}
		c.approx, c.lastApprox = approx, now
	}
	c.s.hub.PublishUser(c.uid, precise, approx)

	cell := geo.Cell(l.LatE7, l.LngE7, geo.ResCell)
	c.s.store.RecordPresence(c.userID, cell)
	if p.Nearby == store.Approx && approx != nil {
		agg := geo.Parent(cell, geo.ResAgg)
		c.mu.Lock()
		oldCell, oldAgg := c.pubCell, c.pubAgg
		c.pubCell, c.pubAgg = cell, agg
		c.mu.Unlock()
		if oldCell != 0 && oldCell != cell {
			c.s.hub.LeaveCell(oldCell, c.uid)
		}
		if oldAgg != agg {
			if oldAgg != 0 {
				c.s.hub.LeaveAgg(oldAgg, c.uid)
			}
			c.s.hub.JoinAgg(agg, c.uid)
		}
		c.s.hub.PublishCell(cell, approx)
	}

	if convoy != "" {
		topic := hub.Topic{Kind: KindConvoy, Key: convoyKey(convoy)}
		c.s.mu.RLock()
		for m := range c.s.convoys[convoy] {
			if m.uid != c.uid && !m.out.Blocks(c.uid) {
				m.out.Deliver(topic, wire.Relation_CONVOY, precise)
			}
		}
		c.s.mu.RUnlock()
		c.s.publishConvoyPos(convoy, precise)
	}
}

func convoyKey(id string) uint64 {
	var h uint64 = 1469598103934665603
	for i := 0; i < len(id); i++ {
		h ^= uint64(id[i])
		h *= 1099511628211
	}
	return h
}

func (c *conn) viewportHolds(lat, lng int32) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.hasVP && lat >= c.vp.MinLat && lat <= c.vp.MaxLat && lng >= c.vp.MinLng && lng <= c.vp.MaxLng
}

func (c *conn) onViewport(v *wire.SetViewport) {
	r := geo.Rect{MinLat: v.MinLatE7, MinLng: v.MinLngE7, MaxLat: v.MaxLatE7, MaxLng: v.MaxLngE7}
	want := map[uint64]struct{}{}
	wantAgg := map[uint64]struct{}{}
	if cells, ok := geo.Cover(r, geo.ResCell); ok {
		for _, h := range cells {
			want[h] = struct{}{}
		}
	} else if cells, ok := geo.Cover(r, geo.ResAgg); ok {
		for _, h := range cells {
			wantAgg[h] = struct{}{}
		}
	}
	c.mu.Lock()
	c.vp, c.hasVP = r, true
	oldCells, oldAggs := c.cells, c.aggs
	c.cells, c.aggs = want, wantAgg
	c.mu.Unlock()

	for h := range oldCells {
		if _, ok := want[h]; !ok {
			c.s.hub.Unsubscribe(hub.CellTopic(h), c.out)
		}
	}
	for h := range want {
		if _, ok := oldCells[h]; !ok {
			c.s.hub.Subscribe(hub.CellTopic(h), c.out, wire.Relation_NEARBY)
		}
	}
	for h := range oldAggs {
		if _, ok := wantAgg[h]; !ok {
			c.s.hub.Unsubscribe(hub.AggTopic(h), c.out)
		}
	}
	for h := range wantAgg {
		if _, ok := oldAggs[h]; !ok {
			c.s.hub.Subscribe(hub.AggTopic(h), c.out, wire.Relation_NEARBY)
		}
	}
}

func (c *conn) joinConvoy(id string) {
	c.s.mu.RLock()
	ca := c.s.cauth
	c.s.mu.RUnlock()
	if id == "" || ca == nil || !ca.IsMember(id, c.uid) {
		c.sendError(wire.Error_UNAUTHORIZED, "not a convoy member")
		return
	}
	c.mu.Lock()
	old := c.convoy
	c.mu.Unlock()
	if old != "" && old != id {
		c.leaveConvoy(old)
	}
	c.mu.Lock()
	c.convoy = id
	c.mu.Unlock()
	c.s.mu.Lock()
	if c.s.convoys[id] == nil {
		c.s.convoys[id] = map[*conn]struct{}{}
	}
	c.s.convoys[id][c] = struct{}{}
	c.s.mu.Unlock()
	if st := ca.Snapshot(id); st != nil {
		c.enqueue(&wire.ServerFrame{Body: &wire.ServerFrame_Convoy{Convoy: st}})
	}
}

func (c *conn) leaveConvoy(id string) {
	if id == "" {
		return
	}
	c.mu.Lock()
	if c.convoy == id {
		c.convoy = ""
	}
	c.mu.Unlock()
	topic := hub.Topic{Kind: KindConvoy, Key: convoyKey(id)}
	c.s.mu.Lock()
	members := c.s.convoys[id]
	delete(members, c)
	if len(members) == 0 {
		delete(c.s.convoys, id)
	}
	var others []*conn
	for m := range members {
		others = append(others, m)
	}
	c.s.mu.Unlock()
	for _, m := range others {
		m.out.Gone(topic, c.uid)
	}
	// The leaver's own view drops the convoy source for members on every node,
	// and other nodes' members drop the leaver (CNV-9).
	c.out.DropSource(topic)
	c.s.publishConvoyGone(id, c.uid)
}

// UIDString formats a wire uid for logs.
func UIDString(uid uint64) string { return strconv.FormatUint(uid, 10) }
