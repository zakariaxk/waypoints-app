package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

var (
	client    = &http.Client{Timeout: 30 * time.Second}
	rateMu    sync.Mutex
	lastFetch time.Time
	robotsMu  sync.Mutex
	robotsOK  = map[string]bool{}
)

// fetch GETs rawURL politely: robots.txt checked once per host and requests are
// spaced at least a second apart.
func fetch(ctx context.Context, rawURL string) ([]byte, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	if err := allowRobots(ctx, u); err != nil {
		return nil, err
	}
	rateMu.Lock()
	if d := time.Since(lastFetch); d < time.Second {
		time.Sleep(time.Second - d)
	}
	lastFetch = time.Now()
	rateMu.Unlock()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "waypoints-guides-drafter/1 (offline curation tool)")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", rawURL, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 4<<20))
}

// allowRobots fetches the host's robots.txt once and reports whether a generic
// agent may GET the path. Unreachable robots.txt means allowed.
func allowRobots(ctx context.Context, u *url.URL) error {
	host := u.Scheme + "://" + u.Host
	robotsMu.Lock()
	ok, seen := robotsOK[host+":"+u.Path]
	robotsMu.Unlock()
	if seen && !ok {
		return fmt.Errorf("robots.txt disallows %s", u.Path)
	}
	if seen {
		return nil
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, host+"/robots.txt", nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		robotsMu.Lock()
		robotsOK[host+":"+u.Path] = true
		robotsMu.Unlock()
		return nil
	}
	defer resp.Body.Close()

	allowed := true
	applies := false
	sc := bufio.NewScanner(io.LimitReader(resp.Body, 1<<20))
	for sc.Scan() {
		line, _, _ := strings.Cut(sc.Text(), "#")
		k, v, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		k = strings.ToLower(strings.TrimSpace(k))
		v = strings.TrimSpace(v)
		switch k {
		case "user-agent":
			applies = v == "*" || strings.Contains(strings.ToLower(v), "waypoints")
		case "disallow":
			if applies && v != "" && strings.HasPrefix(u.Path, v) {
				allowed = false
			}
		}
	}
	robotsMu.Lock()
	robotsOK[host+":"+u.Path] = allowed
	robotsMu.Unlock()
	if !allowed {
		return fmt.Errorf("robots.txt disallows %s", u.Path)
	}
	return nil
}
