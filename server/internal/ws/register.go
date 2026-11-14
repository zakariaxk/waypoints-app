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
	minInterval    = 400 * time.Millisecond
	approxInterval = 15 * time.Second
	maxBadFrames   = 20
	maxFrameBytes  = 16 << 10

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
	a       *app.App
	hub     *hub.Hub
	priv    *privacy.Service
	store   *store.Store
	auth    *auth.Verifier
	bus     bus.Bus
	tick    time.Duration
	bench   bool
	m       serverMetrics
	mu      sync.RWMutex
	conns   map[*conn]struct{}
	byUID   map[uint64]map[*conn]struct{}
	convoys map[string]map[*conn]struct{}
	cauth   ConvoyAuthority
}

type serverMetrics struct {
	conns      *metrics.Gauge
	frames     *metrics.Counter
	badFrames  *metrics.Counter
	rateDrops  *metrics.Counter
	slowClosed *metrics.Counter
	flush      *metrics.Histogram
	bytesOut   *metrics.Counter
}

// Register mounts /v1/rt and provides *Server.
func Register(a *app.App) {
	s := &Server{
		a:       a,
		hub:     app.MustLookup[*hub.Hub](a),
		priv:    app.MustLookup[*privacy.Service](a),
		store:   app.MustLookup[*store.Store](a),
		auth:    app.MustLookup[*auth.Verifier](a),
		bus:     bus.From(a),
		tick:    *tickFlag,
		bench:   auth.Bench(),
		conns:   map[*conn]struct{}{},
		byUID:   map[uint64]map[*conn]struct{}{},
		convoys: map[string]map[*conn]struct{}{},
	}
	reg := a.Metrics
	s.m = serverMetrics{
		conns:      reg.Gauge("ws_connections", "Open realtime connections.", nil),
		frames:     reg.Counter("ws_frames_in_total", "Client frames decoded.", nil),
		badFrames:  reg.Counter("ws_bad_frames_total", "Client frames that failed to decode.", nil),
		rateDrops:  reg.Counter("ws_location_rate_dropped_total", "Location updates dropped by the 400 ms limit.", nil),
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
	a.OnStop("ws", func(context.Context) error { s.closeAll(); return nil })
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

func (s *Server) closeAll() {
	s.mu.RLock()
	var cs []*conn
	for c := range s.conns {
		cs = append(cs, c)
	}
	s.mu.RUnlock()
	for _, c := range cs {
		c.sendError(wire.Error_SHUTTING_DOWN, "shutting down")
		c.ws.Close(websocket.StatusGoingAway, "shutting down")
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
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode:    websocket.CompressionDisabled,
		InsecureSkipVerify: true, // native clients send no Origin
	})
	if err != nil {
		return
	}
	ws.SetReadLimit(maxFrameBytes)
	c := &conn{s: s, ws: ws, log: s.a.Log.With("pkg", "ws")}
	c.run(r.Context())
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
	expiry time.Time
	info   *hub.Info
	out    *Outbox

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
}

func (c *conn) run(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

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
	claims, err := c.s.auth.Verify(ctx, hello.AccessToken)
	if errors.Is(err, auth.ErrSuspended) {
		c.closeWith(wire.Error_UNAUTHORIZED, "suspended", closeUnauthorized)
		return
	}
	if err != nil {
		c.closeWith(wire.Error_UNAUTHORIZED, "unauthorized", closeUnauthorized)
		return
	}
	c.userID, c.expiry = claims.UserID, claims.Expiry

	prof, err := c.s.store.Profile(ctx, c.userID)
	if err != nil {
		c.closeWith(wire.Error_UNAUTHORIZED, "no profile", closeUnauthorized)
		return
	}
	c.uid = prof.UID
	c.info = &hub.Info{MarkerIcon: prof.MarkerIcon, MarkerTrail: prof.MarkerTrail, PaintRGB: prof.PaintRGB,
		DisplayName: prof.DisplayName, CarLabel: prof.CarLabel}

	settings, err := c.s.priv.Acquire(ctx, c.userID)
	if err != nil {
		settings = store.DefaultSettings()
	} else {
		defer c.s.priv.Release(c.userID)
	}
	c.settings = settings
	rels, _ := c.s.store.Relations(ctx, c.userID)

	c.out = newOutbox(c.uid, rels.Blocked, func() {
		c.s.m.slowClosed.Inc()
		go c.ws.Close(closeSlowConsumer, "slow consumer")
	})
	c.s.add(c)
	defer c.s.remove(c)

	welcome := &wire.ServerFrame{Body: &wire.ServerFrame_Welcome{Welcome: &wire.Welcome{
		Uid: c.uid, ServerMs: uint64(time.Now().UnixMilli()), TickMs: uint32(c.s.tick / time.Millisecond), Node: c.s.a.Config.Node,
	}}}
	c.enqueue(welcome)

	friends := map[uint64]struct{}{}
	for _, f := range rels.Friends {
		friends[f] = struct{}{}
		c.s.hub.Subscribe(hub.UserTopic(f), c.out, wire.Relation_FRIEND)
	}
	for _, t := range rels.Teammates {
		if _, ok := friends[t]; !ok {
			c.s.hub.Subscribe(hub.UserTopic(t), c.out, wire.Relation_TEAMMATE)
		}
	}
	c.updatePolicy(time.Now())

	unsubACL, _ := c.s.bus.Subscribe(privacy.ACLSubject(c.uid), func(m bus.Msg) {
		if st, ok := c.s.priv.Apply(c.userID, m.Data); ok {
			c.mu.Lock()
			c.settings = st
			c.mu.Unlock()
			c.updatePolicy(time.Now())
		}
	})

	defer func() {
		if unsubACL != nil {
			unsubACL()
		}
		for _, f := range rels.Friends {
			c.s.hub.Unsubscribe(hub.UserTopic(f), c.out)
		}
		for _, t := range rels.Teammates {
			c.s.hub.Unsubscribe(hub.UserTopic(t), c.out)
		}
		c.mu.Lock()
		cells, aggs, pubCell, pubAgg := c.cells, c.aggs, c.pubCell, c.pubAgg
		c.mu.Unlock()
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
	c.reader(ctx)
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
		if now.After(c.expiry) {
			c.closeWith(wire.Error_UNAUTHORIZED, "token expired", closeUnauthorized)
			return
		}
		switch b := f.Body.(type) {
		case *wire.ClientFrame_Location:
			c.onLocation(b.Location, now)
		case *wire.ClientFrame_Viewport:
			c.onViewport(b.Viewport)
		case *wire.ClientFrame_Ping:
			c.enqueue(&wire.ServerFrame{Body: &wire.ServerFrame_Pong{Pong: &wire.Pong{ClientMs: b.Ping.ClientMs, ServerMs: uint64(now.UnixMilli())}}})
		case *wire.ClientFrame_RefreshToken:
			if cl, err := c.s.auth.Verify(ctx, b.RefreshToken.AccessToken); err == nil && cl.UserID == c.userID {
				c.expiry = cl.Expiry
			} else {
				c.closeWith(wire.Error_UNAUTHORIZED, "unauthorized", closeUnauthorized)
				return
			}
		case *wire.ClientFrame_HomeZones:
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
			c.updatePolicy(now)
		case *wire.ClientFrame_JoinConvoy:
			c.joinConvoy(b.JoinConvoy.ConvoyId)
		case *wire.ClientFrame_LeaveConvoy:
			c.mu.Lock()
			id := c.convoy
			c.mu.Unlock()
			c.leaveConvoy(id)
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
			if m.uid != c.uid {
				m.out.Deliver(topic, wire.Relation_CONVOY, precise)
			}
		}
		c.s.mu.RUnlock()
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
		c.out.Gone(topic, m.uid)
	}
}

// UIDString formats a wire uid for logs.
func UIDString(uid uint64) string { return strconv.FormatUint(uid, 10) }
