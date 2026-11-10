package main

import (
	"fmt"
	"regexp"
	"strings"
	"unicode"
)

// norm lower-cases a token and drops everything but letters and digits, so "F-150",
// "F150", and "f 150"'s pieces compare equal where it matters.
func norm(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// words splits a name on spaces and slashes, keeping the original spelling.
func words(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '/' || r == ',' })
}

// Body, door, and drive words in EPA model names. They are not trims: "Civic 4Dr" and
// "Civic 2Dr" collapse into one Civic, and drive has its own column.
var noiseWords = map[string]bool{
	"2dr": true, "3dr": true, "4dr": true, "5dr": true, "2door": true, "4door": true,
	"awd": true, "fwd": true, "rwd": true, "2wd": true, "4wd": true, "4x4": true, "4x2": true, "ffv": true,
	"convertible": true, "conv": true, "coupe": true, "cabriolet": true, "cabrio": true, "roadster": true,
	"sedan": true, "hatchback": true, "hatch": true, "wagon": true, "wgn": true, "pickup": true,
	"cab": true, "chassis": true, "van": true, "sportwagen": true, "hardtop": true, "liftback": true,
	"sportback": true, "fastback": true, "doublecab": true, "crewcab": true, "regular": true,
	"extended": true, "ext": true, "long": true, "short": true, "bed": true, "lwb": true, "swb": true,
	"targa": false, // a real trim on the 911
}

var gmTruckCode = regexp.MustCompile(`^[ck]\d{1,4}$`)

func isNoise(w string) bool {
	n := norm(w)
	return n == "" || noiseWords[n] || gmTruckCode.MatchString(n)
}

// displayName tidies vPIC's all-caps names ("MUSTANG" -> "Mustang") but leaves short
// codes ("WRX", "GTI", "F-150") alone.
func displayName(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if s != strings.ToUpper(s) {
		return s
	}
	ws := strings.Fields(s)
	for i, w := range ws {
		letters := 0
		for _, r := range w {
			if unicode.IsLetter(r) {
				letters++
			} else {
				letters = -100
			}
		}
		if letters >= 4 {
			ws[i] = string(w[0]) + strings.ToLower(w[1:])
		}
	}
	return strings.Join(ws, " ")
}

func aspirationOf(turbo, super bool) string {
	switch {
	case turbo && super:
		return "twincharged"
	case turbo:
		return "turbo"
	case super:
		return "supercharged"
	}
	return "natural"
}

func driveOf(epa string) string {
	d := strings.ToLower(epa)
	switch {
	case strings.Contains(d, "front"):
		return "fwd"
	case strings.Contains(d, "rear"):
		return "rwd"
	case strings.Contains(d, "all-wheel") && !strings.Contains(d, "4-wheel"):
		return "awd"
	case strings.Contains(d, "4-wheel or all-wheel"):
		return "awd"
	case strings.Contains(d, "4-wheel"), strings.Contains(d, "4wd"):
		return "4wd"
	}
	return ""
}

var gearsRe = regexp.MustCompile(`(\d+)`)

// transmissionOf turns EPA's "Automatic (S10)" into "10-speed automatic".
func transmissionOf(t string) string {
	l := strings.ToLower(t)
	g := ""
	if m := gearsRe.FindString(l); m != "" {
		g = m
	}
	switch {
	case l == "":
		return ""
	case strings.Contains(l, "variable gear") || strings.Contains(l, "av"):
		return "CVT"
	case strings.Contains(l, "a1") || g == "1":
		return "single-speed"
	case strings.Contains(l, "am"):
		return g + "-speed dual-clutch"
	case strings.HasPrefix(l, "manual"):
		return g + "-speed manual"
	case g != "":
		return g + "-speed automatic"
	}
	return "automatic"
}

// transKind is the coarse class used to match test cars: "manual" or "automatic".
func transKind(t string) string {
	if strings.Contains(t, "manual") {
		return "manual"
	}
	return "automatic"
}

// layout guesses cylinder arrangement; EPA gives only the count.
func layout(make, model string, cyl int, displ float64) string {
	m := strings.ToLower(model)
	switch {
	case make == "Subaru" && (cyl == 4 || cyl == 6):
		return "H"
	case make == "Porsche" && cyl == 6 && !strings.Contains(m, "cayenne") && !strings.Contains(m, "macan") && !strings.Contains(m, "panamera"):
		return "H"
	case cyl <= 5:
		return "I"
	case cyl == 6 && (make == "BMW" || (make == "Jeep" && (displ == 4.0 || displ == 4.2)) ||
		(make == "Toyota" && strings.Contains(m, "supra")) || (make == "Ram" && displ >= 5.9) ||
		(make == "Dodge" && displ >= 5.9) || (make == "Ford" && displ == 4.9) ||
		(make == "Volvo" && displ >= 2.9 && displ <= 3.2) || (make == "Chevrolet" && displ == 4.2) ||
		(make == "GMC" && displ == 4.2) || (make == "Mercedes-Benz" && displ == 3.0)):
		return "I"
	case cyl == 12 && (make == "Bentley" || make == "Volkswagen"):
		return "W"
	case cyl == 16:
		return "W"
	}
	return "V"
}

func engineOf(r epaRow) string {
	if r.Displ == 0 {
		return "Electric"
	}
	var s string
	if strings.Contains(strings.ToUpper(r.EngDscr), "ROTARY") || (r.Make == "Mazda" && strings.HasPrefix(strings.ToUpper(r.Model), "RX")) {
		s = fmt.Sprintf("%.1f L rotary", r.Displ)
	} else if r.Cyl > 0 {
		s = fmt.Sprintf("%.1f L %s%d", r.Displ, layout(r.Make, r.Model, r.Cyl, r.Displ), r.Cyl)
	} else {
		s = fmt.Sprintf("%.1f L", r.Displ)
	}
	switch aspirationOf(r.Turbo, r.Super) {
	case "turbo":
		s += " turbo"
	case "supercharged":
		s += " supercharged"
	case "twincharged":
		s += " twincharged"
	}
	if strings.Contains(strings.ToLower(r.ATVType), "hybrid") || strings.Contains(strings.ToUpper(r.EngDscr), "HEV") {
		if strings.Contains(strings.ToLower(r.ATVType), "plug") {
			s += " plug-in hybrid"
		} else {
			s += " hybrid"
		}
	}
	return s
}

// Search aliases written into the FTS text.
var makeAliases = map[string][]string{
	"Chevrolet":       {"chevy"},
	"Volkswagen":      {"vw"},
	"Mercedes-Benz":   {"mercedes", "benz", "merc"},
	"Alfa Romeo":      {"alfa"},
	"Land Rover":      {"landrover"},
	"Rolls-Royce":     {"rolls"},
	"Harley-Davidson": {"harley", "hd"},
}

// ftsText is what search matches: make, model, and trim plus aliases and joined spellings
// of hyphenated names ("F-150" is also "f150").
func ftsText(make, model, trim string) string {
	parts := []string{make, model, trim}
	parts = append(parts, makeAliases[make]...)
	for _, s := range []string{make, model, trim} {
		for _, w := range words(s) {
			if n := norm(w); n != strings.ToLower(w) && n != "" {
				parts = append(parts, n)
			}
		}
	}
	return strings.ToLower(strings.Join(parts, " "))
}
