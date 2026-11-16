package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// quote renders a Go value as a SQL literal. JSON fields are embedded as
// dollar-quoted jsonb so a curator can read the INSERT directly.
func lit(v any) string {
	b, _ := json.Marshal(v)
	s := string(b)
	if !strings.Contains(s, "$g$") {
		return "$g$" + s + "$g$::jsonb"
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'::jsonb"
}

func strLit(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// nullStrLit renders NULL when the field is empty: `model` is nullable and its
// check rejects ''.
func nullStrLit(s string) string {
	if s == "" {
		return "null"
	}
	return strLit(s)
}

// textLit renders a free-text column (tradeoffs/mistakes are `text` in the
// schema, one bullet per line) or NULL when empty.
func textLit(lines []string) string {
	if len(lines) == 0 {
		return "null"
	}
	return strLit(strings.Join(lines, "\n"))
}

// guideSQL renders the review-then-apply INSERT for a draft guide. With
// dedupe and DATABASE_URL set it refuses to emit when a guide with the same
// (make, task) already exists.
func guideSQL(g *guide, dedupe bool) (string, error) {
	if dedupe {
		if err := checkDupe(g); err != nil {
			return "", err
		}
	}
	return fmt.Sprintf(`INSERT INTO public.repair_guides
  (task, make, model, difficulty, time_min_minutes, time_max_minutes, tools, parts, steps, tradeoffs, mistakes, sources, linked_mod_ids)
VALUES (%s, %s, %s, %d, %d, %d, %s, %s, %s, %s, %s, %s, %s);`,
		strLit(g.Task), strLit(g.Make), nullStrLit(g.Model),
		g.Difficulty, g.TimeMin, g.TimeMax,
		lit(g.Tools), lit(g.Parts), lit(g.Steps),
		textLit(g.Tradeoffs), textLit(g.Mistakes), lit(g.Sources), "'[]'::jsonb"), nil
}

// checkDupe asks psql (DATABASE_URL) whether the guide already exists. The
// tool carries no Postgres driver; psql is the offline-query escape hatch.
func checkDupe(g *guide) error {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	q := fmt.Sprintf("SELECT count(*) FROM public.repair_guides WHERE make = %s AND task = %s",
		strLit(g.Make), strLit(g.Task))
	out, err := exec.CommandContext(ctx, "psql", dsn, "-tAX", "-c", q).CombinedOutput()
	if err != nil {
		return fmt.Errorf("dedupe check: %s: %w", strings.TrimSpace(string(out)), err)
	}
	if strings.TrimSpace(string(out)) != "0" {
		return fmt.Errorf("dedupe: a repair_guides row already exists for make=%q task=%q", g.Make, g.Task)
	}
	return nil
}
