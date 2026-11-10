// Package geo holds the H3 helpers the gateway needs: the publisher's cell,
// the approximate (fuzzed) position, viewport covers, and home-zone tests.
//
// Coordinates are int32 in units of 1e-7 degrees, as on the wire.
package geo

import (
	"math"

	"github.com/uber/h3-go/v4"

	"waypoints/server/internal/app"
)

// Resolutions used by the gateway (sections 2.5 and 7.3).
const (
	ResCell   = 7 // interest cells
	ResApprox = 8 // approximate positions snap to this cell's centre
	ResAgg    = 5 // aggregate counts for large viewports
)

// MaxCover is the most cells a viewport subscribes to at one resolution.
const MaxCover = 64

// Register has nothing to wire; geo is a pure helper package.
func Register(a *app.App) {}

// E7 converts degrees to wire units.
func E7(deg float64) int32 { return int32(math.Round(deg * 1e7)) }

// Deg converts wire units to degrees.
func Deg(e7 int32) float64 { return float64(e7) / 1e7 }

// Valid reports whether a wire coordinate is on the globe.
func Valid(latE7, lngE7 int32) bool {
	return latE7 >= -900_000_000 && latE7 <= 900_000_000 && lngE7 >= -1_800_000_000 && lngE7 <= 1_800_000_000
}

// Cell returns the H3 cell containing the point at res, or 0.
func Cell(latE7, lngE7 int32, res int) uint64 {
	c, err := h3.LatLngToCell(h3.NewLatLng(Deg(latE7), Deg(lngE7)), res)
	if err != nil {
		return 0
	}
	return uint64(c)
}

// Parent returns the ancestor of cell at res, or 0.
func Parent(cell uint64, res int) uint64 {
	p, err := h3.Cell(cell).Parent(res)
	if err != nil {
		return 0
	}
	return uint64(p)
}

// Centre returns the centre of a cell in wire units.
func Centre(cell uint64) (latE7, lngE7 int32) {
	ll, err := h3.Cell(cell).LatLng()
	if err != nil {
		return 0, 0
	}
	return E7(ll.Lat), E7(ll.Lng)
}

// Approximate snaps a point to the centre of its resolution 8 cell.
func Approximate(latE7, lngE7 int32) (int32, int32) {
	return Centre(Cell(latE7, lngE7, ResApprox))
}

// Mean cell areas in km² (H3 published averages), used to reject huge
// viewports before asking H3 to enumerate them.
var meanAreaKm2 = map[int]float64{ResAgg: 252.9, ResCell: 5.16}

// Rect is a viewport in wire units.
type Rect struct{ MinLat, MinLng, MaxLat, MaxLng int32 }

func (r Rect) areaKm2() float64 {
	const kmPerDeg = 111.32
	lat0, lat1 := Deg(r.MinLat), Deg(r.MaxLat)
	midLat := (lat0 + lat1) / 2 * math.Pi / 180
	return (lat1 - lat0) * kmPerDeg * (Deg(r.MaxLng) - Deg(r.MinLng)) * kmPerDeg * math.Cos(midLat)
}

// Cover returns the cells at res covering r plus one ring, or nil and false if
// that would exceed MaxCover cells.
func Cover(r Rect, res int) ([]uint64, bool) {
	if r.MaxLat <= r.MinLat || r.MaxLng <= r.MinLng || !Valid(r.MinLat, r.MinLng) || !Valid(r.MaxLat, r.MaxLng) {
		return nil, false
	}
	if area, ok := meanAreaKm2[res]; ok && r.areaKm2()/area > 4*MaxCover {
		return nil, false
	}
	poly := h3.GeoPolygon{GeoLoop: h3.GeoLoop{
		h3.NewLatLng(Deg(r.MinLat), Deg(r.MinLng)),
		h3.NewLatLng(Deg(r.MinLat), Deg(r.MaxLng)),
		h3.NewLatLng(Deg(r.MaxLat), Deg(r.MaxLng)),
		h3.NewLatLng(Deg(r.MaxLat), Deg(r.MinLng)),
	}}
	inner, err := h3.PolygonToCells(poly, res)
	if err != nil {
		return nil, false
	}
	// A viewport smaller than one cell has no cell centre inside it; seed it
	// with the cells under its corners and centre.
	seed := []uint64{
		Cell(r.MinLat, r.MinLng, res), Cell(r.MaxLat, r.MaxLng, res),
		Cell(r.MinLat, r.MaxLng, res), Cell(r.MaxLat, r.MinLng, res),
		Cell(r.MinLat/2+r.MaxLat/2, r.MinLng/2+r.MaxLng/2, res),
	}
	set := map[uint64]struct{}{}
	add := func(c h3.Cell) bool {
		ring, err := c.GridDisk(1)
		if err != nil {
			return true
		}
		for _, n := range ring {
			set[uint64(n)] = struct{}{}
		}
		return len(set) <= MaxCover
	}
	for _, c := range inner {
		if !add(c) {
			return nil, false
		}
	}
	for _, c := range seed {
		if c != 0 && !add(h3.Cell(c)) {
			return nil, false
		}
	}
	out := make([]uint64, 0, len(set))
	for c := range set {
		out = append(out, c)
	}
	return out, true
}

// Zone is a home zone: a circle in wire units and metres.
type Zone struct {
	LatE7, LngE7 int32
	RadiusM      uint32
}

// InAnyZone reports whether the point lies inside any zone.
func InAnyZone(zones []Zone, latE7, lngE7 int32) bool {
	for _, z := range zones {
		if DistanceM(z.LatE7, z.LngE7, latE7, lngE7) <= float64(z.RadiusM) {
			return true
		}
	}
	return false
}

// DistanceM is the haversine distance in metres.
func DistanceM(lat1, lng1, lat2, lng2 int32) float64 {
	const r = 6_371_000.0
	φ1, φ2 := Deg(lat1)*math.Pi/180, Deg(lat2)*math.Pi/180
	dφ := φ2 - φ1
	dλ := (Deg(lng2) - Deg(lng1)) * math.Pi / 180
	h := math.Sin(dφ/2)*math.Sin(dφ/2) + math.Cos(φ1)*math.Cos(φ2)*math.Sin(dλ/2)*math.Sin(dλ/2)
	return 2 * r * math.Asin(math.Min(1, math.Sqrt(h)))
}
