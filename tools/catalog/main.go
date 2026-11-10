// Command catalog builds the bundled vehicle catalog (docs/PLAN.md section 11.1) from
// NHTSA vPIC, EPA vehicles.csv, the EPA test car lists, and overrides.csv.
//
//	go run . -cache .cache -out ../../ios/App/Resources/catalog.sqlite.lzfse
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"sync"
)

func main() {
	cache := flag.String("cache", ".cache", "directory for downloaded source files")
	out := flag.String("out", "../../ios/App/Resources/catalog.sqlite.lzfse", "compressed catalog to write")
	raw := flag.String("sqlite", "", "also keep the uncompressed SQLite here (default: <cache>/catalog.sqlite)")
	version := flag.String("version", "", "catalog version stored in meta (default: today's date)")
	fetchOnly := flag.Bool("fetch-only", false, "download sources into the cache and stop")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	f := newFetcher(*cache)

	vp, err := fetchVPIC(ctx, f)
	if err != nil {
		log.Fatal(err)
	}
	epaRows, err := loadEPA(ctx, f)
	if err != nil {
		log.Fatal(err)
	}
	tests, err := loadTestCars(ctx, f)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("sources: %d vPIC makes, %d EPA rows, %d test car rows (%d live requests)", len(vp), len(epaRows), len(tests), f.live)
	if *fetchOnly {
		return
	}
	overrides, err := loadOverrides("overrides.csv")
	if err != nil {
		log.Fatal(err)
	}

	cat := build(vp, epaRows, tests, overrides)
	sqlitePath := *raw
	if sqlitePath == "" {
		sqlitePath = *cache + "/catalog.sqlite"
	}
	if err := writeSQLite(sqlitePath, cat, *version); err != nil {
		log.Fatal(err)
	}
	if err := compress(sqlitePath, *out); err != nil {
		log.Fatal(err)
	}
	report(sqlitePath, *out)
}

// fetchVPIC downloads every curated make concurrently; the fetcher's ticker keeps the
// combined rate at two requests per second.
func fetchVPIC(ctx context.Context, f *fetcher) (map[string]*vpicMake, error) {
	out := map[string]*vpicMake{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	errs := make(chan error, len(curatedMakes))
	sem := make(chan struct{}, 4)
	for _, m := range curatedMakes {
		if m.VPICID == 0 {
			continue
		}
		wg.Add(1)
		go func(m curatedMake) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			vm, err := f.vpicModels(ctx, m)
			if err != nil {
				errs <- fmt.Errorf("vpic %s: %w", m.Name, err)
				return
			}
			mu.Lock()
			out[m.Name] = vm
			mu.Unlock()
		}(m)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		return nil, err
	}
	return out, nil
}
