package main

import (
	"hash/fnv"
	"sort"
	"strings"
)

type makeRow struct {
	ID      int64
	Name    string
	Popular int // 1-based rank in the picker's Popular section, 0 if not listed
}

type modelRow struct {
	ID       int64
	Make     string
	Name     string
	YearFrom int
	YearTo   int
}

type variantRow struct {
	ID           int64
	ModelID      int64
	Make         string
	Model        string
	Year         int
	Trim         string
	EPAModel     string // raw EPA model name, for override matching only
	EngDscr      string
	Engine       string
	Displ        float64
	Cyl          int
	Asp          string
	Drive        string
	Trans        string
	HP           int
	Torque       int
	Weight       int
	Redline      int
	Gears        string // JSON array of ratios
	Source       string
	fromOverride bool
}

type catalog struct {
	makes    []makeRow
	models   []modelRow
	variants []variantRow
}

// candidate model names per make, from vPIC, with the years each appears.
type modelRef struct {
	name  string
	toks  []string
	years map[int]bool
}

func build(vp map[string]*vpicMake, rows []epaRow, tests []testCar, supplement []supplementRow, overrides []override) *catalog {
	refs := map[string][]modelRef{}
	for mk, vm := range vp {
		seen := map[string]int{}
		for id, name := range vm.models {
			if len(vm.years[id]) == 0 || strings.HasPrefix(name, "'") || norm(name) == "" {
				continue
			}
			dn := displayName(name)
			key := norm(dn)
			if i, ok := seen[key]; ok { // vPIC repeats names under several ids
				for y := range vm.years[id] {
					refs[mk][i].years[y] = true
				}
				continue
			}
			years := map[int]bool{}
			for y := range vm.years[id] {
				years[y] = true
			}
			seen[key] = len(refs[mk])
			refs[mk] = append(refs[mk], modelRef{name: dn, toks: normWords(dn), years: years})
		}
	}

	var vs []variantRow
	covered := map[string]bool{} // make|model|year with at least one EPA variant
	for _, r := range rows {
		model, trim := assignModel(refs[r.Make], r)
		if model == "" {
			continue
		}
		v := variantRow{
			Make: r.Make, Model: model, Year: r.Year, Trim: trim, EPAModel: r.Model, EngDscr: r.EngDscr,
			Engine: engineOf(r), Displ: r.Displ, Cyl: r.Cyl, Asp: aspirationOf(r.Turbo, r.Super),
			Drive: driveOf(r.Drive), Trans: transmissionOf(r.Trany), Source: "epa",
		}
		if v.Engine == "Electric" {
			v.Asp, v.Cyl, v.Displ = "", 0, 0
		}
		vs = append(vs, v)
		covered[key3(r.Make, model, r.Year)] = true
	}

	// Model-years vPIC knows that EPA does not (before 1984, heavy-duty pickups, bikes)
	// get one bare variant so the year step still offers them.
	for mk, list := range refs {
		for _, ref := range list {
			for y := range ref.years {
				if !covered[key3(mk, ref.name, y)] {
					vs = append(vs, variantRow{Make: mk, Model: ref.name, Year: y, Source: "vpic"})
				}
			}
		}
	}

	attachTestCars(vs, tests)
	vs = applySupplement(vs, supplement)
	vs = applyOverrides(vs, overrides)
	vs = dedupe(vs)
	return assemble(vs)
}

func key3(mk, model string, year int) string {
	return mk + "|" + strings.ToLower(model) + "|" + itoa(year)
}

func normWords(s string) []string {
	var out []string
	for _, w := range words(s) {
		if n := norm(w); n != "" {
			out = append(out, n)
		}
	}
	return out
}

// assignModel finds the vPIC model named inside an EPA model string ("Shelby GT350
// Mustang" -> Mustang) and returns it with the leftover words as the trim. The longest
// match wins, and a model sold that year beats one that was not.
func assignModel(refs []modelRef, r epaRow) (model, trim string) {
	ws := words(r.Model)
	toks := make([]string, len(ws))
	for i, w := range ws {
		toks[i] = norm(w)
	}
	best, bestScore, bestAt := -1, 0, 0
	for i, ref := range refs {
		at := findRun(toks, ref.toks)
		if at < 0 {
			// "F150" in EPA against "F-150 ..." in vPIC: compare joined spellings too.
			at = findJoined(toks, strings.Join(ref.toks, ""))
			if at < 0 {
				continue
			}
		}
		score := len(strings.Join(ref.toks, "")) * 2
		if ref.years[r.Year] {
			score += 1000
		}
		if score > bestScore {
			best, bestScore, bestAt = i, score, at
		}
	}
	var rest []string
	if best >= 0 {
		model = refs[best].name
		n := len(refs[best].toks)
		if findRun(toks, refs[best].toks) < 0 {
			n = 1
		}
		rest = append(append(rest, ws[:bestAt]...), ws[bestAt+n:]...)
	} else {
		// No vPIC model: use EPA's base model, cut at its first slash ("Impreza/Outback Sport").
		base := r.BaseModel
		if base == "" {
			base = r.Model
		}
		if i := strings.Index(base, "/"); i > 0 {
			base = base[:i]
		}
		var bw []string
		for _, w := range words(base) {
			if !isNoise(w) {
				bw = append(bw, w)
			}
		}
		if len(bw) == 0 {
			return "", ""
		}
		model = strings.Join(bw, " ")
		bt := normWords(model)
		at := findRun(toks, bt)
		if at >= 0 {
			rest = append(append(rest, ws[:at]...), ws[at+len(bt):]...)
		} else {
			rest = ws
		}
	}
	var tw []string
	for _, w := range rest {
		if !isNoise(w) {
			tw = append(tw, w)
		}
	}
	return model, strings.Join(tw, " ")
}

func findRun(hay, needle []string) int {
	if len(needle) == 0 || len(needle) > len(hay) {
		return -1
	}
outer:
	for i := 0; i+len(needle) <= len(hay); i++ {
		for j := range needle {
			if hay[i+j] != needle[j] {
				continue outer
			}
		}
		return i
	}
	return -1
}

func findJoined(hay []string, joined string) int {
	for i, t := range hay {
		if t == joined {
			return i
		}
	}
	return -1
}

// attachTestCars fills rated horsepower and an estimated curb weight (equivalent test
// weight minus 300 lb) from the EPA test car lists, matching on year, make, displacement,
// cylinders, transmission class, and a shared model word.
func attachTestCars(vs []variantRow, tests []testCar) {
	type ym struct {
		y  int
		mk string
	}
	idx := map[ym][]testCar{}
	for _, t := range tests {
		idx[ym{t.Year, t.Make}] = append(idx[ym{t.Year, t.Make}], t)
	}
	for i := range vs {
		v := &vs[i]
		if v.Source != "epa" || v.Displ == 0 {
			continue
		}
		cands := idx[ym{v.Year, strings.ToLower(v.Make)}]
		modelToks := normWords(v.Model)
		trimToks := normWords(v.Trim)
		var match []testCar
		var trimMatch []testCar
		for _, t := range cands {
			if abs(t.Displ-v.Displ) > 0.051 || (t.Cyl != 0 && v.Cyl != 0 && t.Cyl != v.Cyl) || t.Trans != transKind(v.Trans) {
				continue
			}
			tt := normWords(t.Model)
			if !overlaps(tt, modelToks) && !strings.Contains(strings.Join(tt, ""), strings.Join(modelToks, "")) {
				continue
			}
			match = append(match, t)
			if len(trimToks) > 0 && overlaps(tt, trimToks) {
				trimMatch = append(trimMatch, t)
			}
		}
		if len(trimMatch) > 0 {
			match = trimMatch
		}
		if len(match) == 0 {
			continue
		}
		hp, etw := modeHP(match)
		v.HP = hp
		if etw > 0 {
			v.Weight = etw - 300
		}
		v.Source = "epa+test"
	}
}

func overlaps(a, b []string) bool {
	for _, x := range a {
		for _, y := range b {
			if x == y && len(x) > 1 {
				return true
			}
		}
	}
	return false
}

// modeHP returns the most common rated horsepower (lower on ties) and the lightest
// test weight seen with it.
func modeHP(ts []testCar) (int, int) {
	count := map[int]int{}
	for _, t := range ts {
		count[t.HP]++
	}
	best := 0
	for hp, n := range count {
		if n > count[best] || (n == count[best] && hp < best) {
			best = hp
		}
	}
	etw := 0
	for _, t := range ts {
		if t.HP == best && t.ETW > 0 && (etw == 0 || t.ETW < etw) {
			etw = t.ETW
		}
	}
	return best, etw
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}

// dedupe collapses rows that differ only in body style (EPA lists coupe and convertible
// separately); the first row of a group keeps its specs, and missing specs are filled
// from the others.
func dedupe(vs []variantRow) []variantRow {
	type k struct {
		mk, model, trim, engine, drive, trans string
		year                                  int
	}
	idx := map[k]int{}
	var out []variantRow
	for _, v := range vs {
		key := k{v.Make, strings.ToLower(v.Model), strings.ToLower(v.Trim), v.Engine, v.Drive, v.Trans, v.Year}
		if i, ok := idx[key]; ok {
			o := &out[i]
			if o.HP == 0 {
				o.HP = v.HP
			}
			if o.Weight == 0 || (v.Weight > 0 && v.Weight < o.Weight && !o.fromOverride) {
				o.Weight = v.Weight
			}
			continue
		}
		idx[key] = len(out)
		out = append(out, v)
	}
	// A bare vPIC row is dropped when the same model-year has a real variant (overrides
	// can add those after the coverage check).
	real := map[string]bool{}
	for _, v := range out {
		if v.Source != "vpic" {
			real[key3(v.Make, v.Model, v.Year)] = true
		}
	}
	kept := out[:0]
	for _, v := range out {
		if v.Source == "vpic" && real[key3(v.Make, v.Model, v.Year)] {
			continue
		}
		kept = append(kept, v)
	}
	return kept
}

// assemble assigns stable ids (hashes of names, so a car's catalog_variant_id survives a
// catalog rebuild) and derives model year spans.
func assemble(vs []variantRow) *catalog {
	c := &catalog{}
	makeIDs := map[string]int64{}
	usedMake := map[int64]bool{}
	present := map[string]bool{}
	for _, v := range vs {
		present[v.Make] = true
	}
	for _, m := range curatedMakes {
		if !present[m.Name] {
			continue
		}
		id := stableID("make|"+strings.ToLower(m.Name), 1<<31, usedMake)
		makeIDs[m.Name] = id
		pop := 0
		for i, p := range popularMakes {
			if p == m.Name {
				pop = i + 1
			}
		}
		c.makes = append(c.makes, makeRow{ID: id, Name: m.Name, Popular: pop})
	}

	type span struct {
		from, to int
		name     string
	}
	spans := map[string]*span{}
	for _, v := range vs {
		k := v.Make + "|" + strings.ToLower(v.Model)
		s := spans[k]
		if s == nil {
			s = &span{from: v.Year, to: v.Year, name: v.Model}
			spans[k] = s
		}
		if v.Year < s.from {
			s.from = v.Year
		}
		if v.Year > s.to {
			s.to = v.Year
		}
	}
	keys := make([]string, 0, len(spans))
	for k := range spans {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	modelIDs := map[string]int64{}
	usedModel := map[int64]bool{}
	for _, k := range keys {
		s := spans[k]
		mk := k[:strings.Index(k, "|")]
		id := stableID("model|"+strings.ToLower(k), 1<<31, usedModel)
		modelIDs[k] = id
		c.models = append(c.models, modelRow{ID: id, Make: mk, Name: s.name, YearFrom: s.from, YearTo: s.to})
	}

	sort.SliceStable(vs, func(i, j int) bool {
		a, b := vs[i], vs[j]
		if a.Make != b.Make {
			return a.Make < b.Make
		}
		if a.Model != b.Model {
			return a.Model < b.Model
		}
		if a.Year != b.Year {
			return a.Year > b.Year
		}
		if a.Trim != b.Trim {
			return a.Trim < b.Trim
		}
		if a.Engine != b.Engine {
			return a.Engine < b.Engine
		}
		if a.Drive != b.Drive {
			return a.Drive < b.Drive
		}
		return a.Trans < b.Trans
	})
	usedVariant := map[int64]bool{}
	for i := range vs {
		v := &vs[i]
		key := strings.ToLower(strings.Join([]string{v.Make, v.Model, itoa(v.Year), v.Trim, v.Engine, v.Drive, v.Trans}, "|"))
		v.ID = stableID("variant|"+key, 1<<40, usedVariant)
		v.ModelID = modelIDs[v.Make+"|"+strings.ToLower(v.Model)]
	}
	c.variants = vs
	return c
}

// stableID hashes key into [1, limit), probing past collisions.
func stableID(key string, limit int64, used map[int64]bool) int64 {
	h := fnv.New64a()
	h.Write([]byte(key))
	id := int64(h.Sum64()%uint64(limit-1)) + 1
	for used[id] {
		id = id%(limit-1) + 1
	}
	used[id] = true
	return id
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
