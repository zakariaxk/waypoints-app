package main

import (
	"encoding/csv"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
)

// supplementRow is one row of supplement.csv: a model the federal data does not cover
// (classics before 1981, grey-market imports) with its year span and the page that
// documents it (PRD GAR-2). An optional trim names the generation or version.
type supplementRow struct {
	Make, Model string
	From, To    int
	Trim        string
	Source      string
}

func loadSupplement(path string) ([]supplementRow, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.Comment = '#'
	r.FieldsPerRecord = -1
	recs, err := r.ReadAll()
	if err != nil {
		return nil, err
	}
	if len(recs) == 0 {
		return nil, nil
	}
	col := columns(recs[0])
	var out []supplementRow
	for n, rec := range recs[1:] {
		get := func(k string) string { return field(rec, col, k) }
		from, _ := strconv.Atoi(get("year_from"))
		to, _ := strconv.Atoi(get("year_to"))
		s := supplementRow{Make: get("make"), Model: get("model"), From: from, To: to, Trim: get("trim"), Source: get("source_url")}
		if s.Make == "" || s.Model == "" || s.From == 0 || s.To < s.From {
			return nil, fmt.Errorf("supplement.csv line %d: make, model, and years are required", n+2)
		}
		if !strings.HasPrefix(s.Source, "http") {
			return nil, fmt.Errorf("supplement.csv line %d: source_url is required", n+2)
		}
		out = append(out, s)
	}
	return out, nil
}

// applySupplement adds one bare variant per supplement model-year the catalog lacks.
// A model already in the catalog under another spelling of case keeps that spelling, so a
// 1969 Camaro joins the Camaro the federal data starts in 1982.
func applySupplement(vs []variantRow, rows []supplementRow) []variantRow {
	curated := map[string]string{}
	for _, m := range curatedMakes {
		curated[strings.ToLower(m.Name)] = m.Name
	}
	names := map[string]string{} // make|norm(model) -> catalog spelling
	covered := map[string]bool{} // make|model|year with a federal (non-vPIC-bare) variant
	have := map[string]bool{}    // make|model|year|trim added here
	for _, v := range vs {
		names[v.Make+"|"+norm(v.Model)] = v.Model
		if v.Source != "vpic" {
			covered[key3(v.Make, v.Model, v.Year)] = true
		}
	}
	for _, s := range rows {
		mk, ok := curated[strings.ToLower(s.Make)]
		if !ok {
			log.Printf("supplement.csv: make %s is not in makes.go; row skipped", s.Make)
			continue
		}
		model := s.Model
		if n, ok := names[mk+"|"+norm(model)]; ok {
			model = n
		} else {
			names[mk+"|"+norm(model)] = model
		}
		for y := s.From; y <= s.To && y <= lastYear; y++ {
			k := key3(mk, model, y) + "|" + strings.ToLower(s.Trim)
			if covered[key3(mk, model, y)] || have[k] {
				continue
			}
			have[k] = true
			vs = append(vs, variantRow{Make: mk, Model: model, Year: y, Trim: s.Trim, Source: "supplement"})
		}
	}
	return vs
}
