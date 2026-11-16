// Command guides is the offline scrape pipeline for KNW-5 (docs/PRD.md section
// 8.10 W13-C): it fetches a forum install thread or manual page, extracts facts
// heuristically, and emits a draft repair guide JSON for a curator to review.
// Nothing is auto-published; --emit-sql only prints an INSERT for review.
//
//	go run . -url https://example.com/install-thread -make BMW -model "E46 330i" -task "brake pad replacement"
//	go run . -file fixture.html -make Mazda -task "oil change" -emit-sql
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
)

type part struct {
	Name        string `json:"name"`
	EstCostLow  int    `json:"est_cost_cents_low"`
	EstCostHigh int    `json:"est_cost_cents_high"`
	PartNumber  string `json:"part_number,omitempty"`
}

type guide struct {
	Task       string   `json:"task"`
	Make       string   `json:"make"`
	Model      string   `json:"model,omitempty"`
	Difficulty int      `json:"difficulty"`
	TimeMin    int      `json:"time_min"`
	TimeMax    int      `json:"time_max"`
	Tools      []string `json:"tools"`
	Parts      []part   `json:"parts"`
	Steps      []string `json:"steps"`
	Tradeoffs  []string `json:"tradeoffs"`
	Mistakes   []string `json:"mistakes"`
	Sources    []string `json:"sources"`
}

func main() {
	rawURL := flag.String("url", "", "page to scrape (http/https or file://)")
	file := flag.String("file", "", "read HTML from a local file instead of fetching")
	out := flag.String("out", "", "write the draft JSON here (default: stdout)")
	make_ := flag.String("make", "", "vehicle make the guide applies to")
	model := flag.String("model", "", "optional model/variant")
	task := flag.String("task", "", "task title, e.g. \"front brake pad replacement\"")
	difficulty := flag.Int("difficulty", 3, "difficulty 1-5")
	timeMin := flag.Int("time-min", 30, "estimated minutes, low")
	timeMax := flag.Int("time-max", 120, "estimated minutes, high")
	emitSQL := flag.Bool("emit-sql", false, "also print an INSERT INTO public.repair_guides statement")
	dedupe := flag.Bool("dedupe", false, "with -emit-sql and DATABASE_URL set, refuse to emit if a guide with the same (make, task) exists")
	flag.Parse()

	if *rawURL == "" && *file == "" {
		log.Fatal("guides: -url or -file is required")
	}
	if *make_ == "" || *task == "" {
		log.Fatal("guides: -make and -task are required")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	var body []byte
	var err error
	source := *rawURL
	switch {
	case *file != "":
		body, err = os.ReadFile(*file)
		if source == "" {
			source = "file://" + *file
		}
	case strings.HasPrefix(*rawURL, "file://"):
		body, err = os.ReadFile(strings.TrimPrefix(*rawURL, "file://"))
	default:
		body, err = fetch(ctx, *rawURL)
	}
	if err != nil {
		log.Fatal(err)
	}

	text := htmlText(string(body))
	facts := extract(text)

	g := &guide{
		Task:       *task,
		Make:       *make_,
		Model:      *model,
		Difficulty: *difficulty,
		TimeMin:    *timeMin,
		TimeMax:    *timeMax,
		Tools:      facts.tools,
		Parts:      facts.parts,
		Steps:      facts.steps,
		Tradeoffs:  facts.tradeoffs,
		Mistakes:   facts.cautions,
		Sources:    []string{source},
	}
	if len(g.Steps) == 0 {
		// Thin extraction: skeleton TODOs for the curator, never scraped prose.
		g.Steps = []string{"TODO(curator): describe the procedure", "TODO(curator): reassembly and torque specs"}
	}
	if len(g.Tools) == 0 {
		g.Tools = []string{}
	}
	if len(g.Parts) == 0 {
		g.Parts = []part{}
	}
	if len(g.Tradeoffs) == 0 {
		g.Tradeoffs = []string{}
	}
	if len(g.Mistakes) == 0 {
		g.Mistakes = []string{}
	}

	doc, err := json.MarshalIndent(g, "", "  ")
	if err != nil {
		log.Fatal(err)
	}
	if *out != "" {
		if err := os.WriteFile(*out, append(doc, '\n'), 0o644); err != nil {
			log.Fatal(err)
		}
		log.Printf("wrote %s", *out)
	} else {
		fmt.Println(string(doc))
	}

	if *emitSQL {
		sqlText, err := guideSQL(g, *dedupe)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Println(sqlText)
	}
}
