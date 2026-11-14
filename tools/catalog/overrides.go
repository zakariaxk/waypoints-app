package main

import (
	"encoding/csv"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
)

// override is one row of overrides.csv: a named trim with enthusiast specs for a range of
// model years. Match columns (displ, cyl, aspiration, trans, epa_contains) pick the EPA
// variants it labels; when a year has none, the row is inserted as its own variant.
type override struct {
	Make, Model string
	From, To    int
	Trim        string
	Displ       float64
	Cyl         int
	Asp         string
	Trans       string // "manual", "automatic", an exact "6-speed manual", or "" for any; also the inserted transmission
	EPAContains []string
	Drive       string
	HP, Torque  int
	Weight      int
	Redline     int
	Gears       string
	Source      string // page the numbers were read from (PRD GAR-8)
}

func loadOverrides(path string) ([]override, error) {
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
	col := columns(recs[0])
	var out []override
	for n, rec := range recs[1:] {
		get := func(k string) string { return field(rec, col, k) }
		num := func(k string) int { v, _ := strconv.Atoi(get(k)); return v }
		o := override{
			Make: get("make"), Model: get("model"), From: num("year_from"), To: num("year_to"),
			Trim: get("trim"), Cyl: num("cyl"), Asp: get("aspiration"), Trans: get("trans"),
			Drive: get("drive"), HP: num("hp"), Torque: num("torque_lbft"), Weight: num("weight_lb"),
			Redline: num("redline"), Source: get("source_url"),
		}
		o.Displ, _ = strconv.ParseFloat(get("displ"), 64)
		if e := get("epa_contains"); e != "" {
			o.EPAContains = strings.Split(strings.ToLower(e), "|")
		}
		if g := get("gears"); g != "" {
			o.Gears = "[" + strings.ReplaceAll(g, ";", ",") + "]"
		}
		if o.Make == "" || o.Model == "" || o.From == 0 || o.To < o.From {
			return nil, fmt.Errorf("overrides.csv line %d: make, model, and years are required", n+2)
		}
		if !strings.HasPrefix(o.Source, "http") {
			return nil, fmt.Errorf("overrides.csv line %d: source_url is required", n+2)
		}
		out = append(out, o)
	}
	return out, nil
}

func (o override) matches(v variantRow) bool {
	if v.fromOverride || v.Source == "vpic" || !strings.EqualFold(v.Make, o.Make) || !strings.EqualFold(v.Model, o.Model) ||
		v.Year < o.From || v.Year > o.To {
		return false
	}
	if o.Displ != 0 && abs(v.Displ-o.Displ) > 0.051 {
		return false
	}
	if o.Cyl != 0 && v.Cyl != o.Cyl {
		return false
	}
	if o.Asp != "" && v.Asp != o.Asp {
		return false
	}
	if o.Trans != "" && !o.transMatches(v.Trans) {
		return false
	}
	if len(o.EPAContains) > 0 {
		raw := " " + strings.ToLower(v.EPAModel+" "+v.EngDscr) + " "
		for _, s := range o.EPAContains {
			if strings.Contains(raw, s) {
				return true
			}
		}
		return false
	}
	return v.Trim == ""
}

func applyOverrides(vs []variantRow, os []override) []variantRow {
	known := map[string]bool{}
	for _, v := range vs {
		known[strings.ToLower(v.Make+"|"+v.Model)] = true
	}
	for _, o := range os {
		if !known[strings.ToLower(o.Make+"|"+o.Model)] {
			log.Printf("overrides.csv: no catalog model %s %s; row skipped", o.Make, o.Model)
			continue
		}
		hit := map[int]bool{}
		for i := range vs {
			if o.matches(vs[i]) {
				v := &vs[i]
				if o.Trim != "" {
					v.Trim = o.Trim
				}
				o.fill(v)
				hit[v.Year] = true
			}
		}
		if o.Displ == 0 && o.Cyl == 0 {
			continue
		}
		for y := o.From; y <= o.To; y++ {
			if hit[y] || y > lastYear {
				continue
			}
			v := variantRow{
				Make: o.Make, Model: o.Model, Year: y, Trim: o.Trim, Displ: o.Displ, Cyl: o.Cyl,
				Asp: o.Asp, Drive: o.Drive,
			}
			if v.Asp == "" {
				v.Asp = "natural"
			}
			v.Engine = engineOf(epaRow{Make: o.Make, Model: o.Model, Displ: o.Displ, Cyl: o.Cyl,
				Turbo: v.Asp == "turbo" || v.Asp == "twincharged", Super: v.Asp == "supercharged" || v.Asp == "twincharged"})
			v.Trans = o.Trans
			o.fill(&v)
			vs = append(vs, v)
		}
	}
	return vs
}

// transMatches compares a transmission class ("manual", "automatic") or, when the row names
// one ("6-speed manual"), the exact transmission, which separates trims EPA lists alike.
func (o override) transMatches(t string) bool {
	if strings.Contains(o.Trans, "speed") || o.Trans == "CVT" {
		return strings.EqualFold(t, o.Trans)
	}
	return transKind(t) == o.Trans
}

func (o override) fill(v *variantRow) {
	v.fromOverride = true
	v.Source = "override"
	if o.HP > 0 {
		v.HP = o.HP
	}
	if o.Torque > 0 {
		v.Torque = o.Torque
	}
	if o.Weight > 0 {
		v.Weight = o.Weight
	}
	if o.Redline > 0 {
		v.Redline = o.Redline
	}
	if o.Gears != "" {
		v.Gears = o.Gears
	}
	if v.Drive == "" {
		v.Drive = o.Drive
	}
}
