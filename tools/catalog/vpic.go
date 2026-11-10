package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const vpicBase = "https://vpic.nhtsa.dot.gov/api/vehicles/"

// fetcher caches every response on disk and keeps live requests to at most two per second
// (vPIC publishes no rate limit; plan section 11.1).
type fetcher struct {
	dir    string
	client *http.Client
	tick   <-chan time.Time
	mu     sync.Mutex
	live   int
}

func newFetcher(dir string) *fetcher {
	return &fetcher{
		dir:    dir,
		client: &http.Client{Timeout: 60 * time.Second},
		tick:   time.NewTicker(500 * time.Millisecond).C,
	}
}

// get returns the body for rawURL, from cache when present.
func (f *fetcher) get(ctx context.Context, rawURL, cacheName string) ([]byte, error) {
	path := filepath.Join(f.dir, cacheName)
	if b, err := os.ReadFile(path); err == nil {
		return b, nil
	}
	var lastErr error
	for attempt := 0; attempt < 4; attempt++ {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-f.tick:
		}
		b, err := f.fetch(ctx, rawURL)
		if err == nil {
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return nil, err
			}
			if err := os.WriteFile(path, b, 0o644); err != nil {
				return nil, err
			}
			f.mu.Lock()
			f.live++
			f.mu.Unlock()
			return b, nil
		}
		lastErr = err
		time.Sleep(time.Duration(attempt+1) * 2 * time.Second)
	}
	return nil, fmt.Errorf("%s: %w", rawURL, lastErr)
}

func (f *fetcher) fetch(ctx context.Context, rawURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "waypoints-catalog-builder/1")
	resp, err := f.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("status %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

type vpicModel struct {
	ModelID   int    `json:"Model_ID"`
	ModelName string `json:"Model_Name"`
}

type vpicResponse struct {
	Results []vpicModel `json:"Results"`
}

// vpicMake is everything vPIC says about one make: model names and the years each appears.
type vpicMake struct {
	models map[int]string       // Model_ID -> name, restricted to the wanted vehicle types
	years  map[int]map[int]bool // Model_ID -> model years
}

var carTypes = []string{"Passenger Car", "Multipurpose Passenger Vehicle (MPV)", "Truck"}

func (f *fetcher) vpicModels(ctx context.Context, m curatedMake) (*vpicMake, error) {
	out := &vpicMake{models: map[int]string{}, years: map[int]map[int]bool{}}
	types := carTypes
	if m.Bike {
		types = []string{"Motorcycle"}
	}
	for _, t := range types {
		u := fmt.Sprintf("%sGetModelsForMakeIdYear/makeId/%d/vehicletype/%s?format=json", vpicBase, m.VPICID, url.PathEscape(strings.ToLower(t)))
		name := fmt.Sprintf("vpic/type-%d-%s.json", m.VPICID, slug(t))
		var r vpicResponse
		if err := f.getJSON(ctx, u, name, &r); err != nil {
			return nil, err
		}
		for _, x := range r.Results {
			out.models[x.ModelID] = strings.TrimSpace(x.ModelName)
		}
	}
	for y := firstYear; y <= lastYear; y++ {
		u := fmt.Sprintf("%sGetModelsForMakeIdYear/makeId/%d/modelyear/%d?format=json", vpicBase, m.VPICID, y)
		name := fmt.Sprintf("vpic/year-%d-%d.json", m.VPICID, y)
		var r vpicResponse
		if err := f.getJSON(ctx, u, name, &r); err != nil {
			return nil, err
		}
		for _, x := range r.Results {
			if _, ok := out.models[x.ModelID]; !ok {
				continue
			}
			if out.years[x.ModelID] == nil {
				out.years[x.ModelID] = map[int]bool{}
			}
			out.years[x.ModelID][y] = true
		}
	}
	return out, nil
}

func (f *fetcher) getJSON(ctx context.Context, u, cacheName string, v any) error {
	b, err := f.get(ctx, u, cacheName)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, v); err != nil {
		os.Remove(filepath.Join(f.dir, cacheName))
		return fmt.Errorf("%s: %w", u, err)
	}
	return nil
}

func slug(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}
