package main

import (
	"fmt"
	"html"
	"regexp"
	"strings"
)

var (
	reSkip       = regexp.MustCompile(`(?is)</?(script|style|noscript|head|svg|form)[^>]*>`)
	reTag        = regexp.MustCompile(`(?s)<[^>]+>`)
	reBlock      = regexp.MustCompile(`(?i)<\s*(br|/p|/div|/li|/h[1-6]|/tr|li|p|div|h[1-6]|tr)[^>]*>`)
	reSpace      = regexp.MustCompile(`[ \t]+`)
	reStepLine   = regexp.MustCompile(`^\s*(?:step\s*)?(\d{1,2})[.)]\s+(.+)`)
	reTorque     = regexp.MustCompile(`(?i)\b(\d+(?:\.\d+)?)\s*(ft-?lbs?|foot-?pounds?|nm|newton-?meters?|in-?lbs?)\b`)
	rePartNumber = regexp.MustCompile(`\b(?:part\s*(?:number|no\.?|#)|p/?n|oem)\s*[:#.\-]\s*([A-Z0-9][A-Z0-9.\-/]{4,20})\b`)
	reImperative = regexp.MustCompile(`(?i)^(remove|install|unbolt|bolt|loosen|tighten|torque|jack|lift|raise|lower|disconnect|connect|drain|refill|fill|replace|pull|push|pry|slide|unplug|plug|detach|attach|unscrew|screw|clip|unclip|grease|clean|inspect|check|align|bleed|pump|press|extract|insert|seat|mount|support|chock|locate|mark|measure|set|turn|rotate|spin|crack|undo|reinstall|refit|hook|hang|swing|drop|hold|release|apply|coat|lubricate|take|put|place|use|undo)\b`)
	reCaution    = regexp.MustCompile(`(?i)\b(caution|warning|careful|do not|don't|never|avoid|hot|support (?:the )?(?:car|vehicle)|jack stands?|wear (?:gloves|eye)|disconnect the battery|chock)\b`)
	reTradeoff   = regexp.MustCompile(`(?i)\b(instead of|rather than|cheaper|oem vs|aftermarket|worth it|trade-?off|downside|however|on the other hand|pros? and cons?)\b`)
	reFunc       = regexp.MustCompile(`(?i)\b(the|a|an|your|its|with|from|into)\b`)
	reCite       = regexp.MustCompile(`\[\d+\]`)
	reCost       = regexp.MustCompile(`\$\s*(\d+(?:\.\d+)?)`)
)

// toolWords maps a regex word to the canonical tool name emitted.
var toolWords = []struct {
	re   *regexp.Regexp
	name string
}{
	{regexp.MustCompile(`(?i)\bjack stands?\b`), "jack stands"},
	{regexp.MustCompile(`(?i)\b(floor |hydraulic )?jack\b`), "jack"},
	{regexp.MustCompile(`(?i)\btorque wrench\b`), "torque wrench"},
	{regexp.MustCompile(`(?i)\bbreaker bar\b`), "breaker bar"},
	{regexp.MustCompile(`(?i)\b(\d+)\s*mm\s+(socket|wrench|spanner)\b`), "${1}mm socket"},
	{regexp.MustCompile(`(?i)\b(\d+)\s*mm\b`), "${1}mm wrench/socket"},
	{regexp.MustCompile(`(?i)\bimpact (?:wrench|gun|driver)\b`), "impact wrench"},
	{regexp.MustCompile(`(?i)\bhex (?:key|allen)s?\b|\ballen (?:key|wrench)\b`), "hex/Allen keys"},
	{regexp.MustCompile(`(?i)\btorx\b`), "Torx bits"},
	{regexp.MustCompile(`(?i)\bflat\s*head|flatblade\b`), "flathead screwdriver"},
	{regexp.MustCompile(`(?i)\bphillips\b`), "Phillips screwdriver"},
	{regexp.MustCompile(`(?i)\bpliers\b`), "pliers"},
	{regexp.MustCompile(`(?i)\bpuller\b`), "puller"},
	{regexp.MustCompile(`(?i)\b(caliper|piston) (?:compressor|tool|spreader)\b`), "caliper compressor"},
	{regexp.MustCompile(`(?i)\b(?:oil )?filter wrench\b`), "filter wrench"},
	{regexp.MustCompile(`(?i)\bdrain pan\b`), "drain pan"},
	{regexp.MustCompile(`(?i)\bfunnel\b`), "funnel"},
	{regexp.MustCompile(`(?i)\bwire brush\b`), "wire brush"},
	{regexp.MustCompile(`(?i)\bpenetrating oil\b|\bpb blaster\b`), "penetrating oil"},
	{regexp.MustCompile(`(?i)\bc-?clamp\b`), "C-clamp"},
	{regexp.MustCompile(`(?i)\btrim (?:tool|removal)\b|\bpry (?:tool|bar)\b`), "pry/trim tool"},
	{regexp.MustCompile(`(?i)\bratchet\b`), "ratchet"},
	{regexp.MustCompile(`(?i)\bcreeper\b`), "creeper"},
	{regexp.MustCompile(`(?i)\bwheel chocks?\b`), "wheel chocks"},
	{regexp.MustCompile(`(?i)\bgloves\b`), "gloves"},
	{regexp.MustCompile(`(?i)\bbrake (?:cleaner|clean)\b`), "brake cleaner"},
}

var partWords = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\b(brake pads?|rotors?|calipers?|brake lines?)\b`),
	regexp.MustCompile(`(?i)\b(oil filter|cabin filter|air filter|fuel filter)\b`),
	regexp.MustCompile(`(?i)\b(spark plugs?|coil packs?|ignition coils?)\b`),
	regexp.MustCompile(`(?i)\b(control arms?|ball joints?|tie rods?|sway ?bar links?|bushings?|struts?|shocks?|coilovers?)\b`),
	regexp.MustCompile(`(?i)\b(gaskets?|seals?|o-?rings?|belts?|hoses?|thermostat|water pump|clutch|flywheel)\b`),
	regexp.MustCompile(`(?i)\b(engine oil|gear oil|brake fluid|coolant|antifreeze|transmission fluid|power steering fluid)\b`),
	regexp.MustCompile(`(?i)\b(wheel bearings?|hub assembly|axle|cv joints?|driveshaft)\b`),
	regexp.MustCompile(`(?i)\b(muffler|exhaust|downpipe|cat|o2 sensor|oxygen sensor)\b`),
	regexp.MustCompile(`(?i)\b(battery|alternator|starter|bulbs?|headlights?|taillights?)\b`),
	regexp.MustCompile(`(?i)\b(wipers?|wiper blades?|fenders?|bumpers?|panels?)\b`),
}

// htmlText strips markup to readable plain text: scripts/styles removed, block
// tags become newlines, entities decoded.
func htmlText(doc string) string {
	// Drop script/style/etc. bodies by blanking everything between their tags.
	for _, tag := range []string{"script", "style", "noscript", "head", "svg", "form"} {
		open := "<" + tag
		for {
			i := strings.Index(strings.ToLower(doc), open)
			j := strings.Index(strings.ToLower(doc), "</"+tag+">")
			if i < 0 || j < 0 || j < i {
				break
			}
			doc = doc[:i] + " " + doc[j+len(tag)+3:]
		}
	}
	doc = reSkip.ReplaceAllString(doc, " ")
	doc = reBlock.ReplaceAllString(doc, "\n")
	doc = reTag.ReplaceAllString(doc, " ")
	doc = html.UnescapeString(doc)
	var b strings.Builder
	for _, line := range strings.Split(doc, "\n") {
		line = reSpace.ReplaceAllString(strings.TrimSpace(line), " ")
		if line != "" {
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

type facts struct {
	steps     []string
	tools     []string
	parts     []part
	cautions  []string
	tradeoffs []string
}

// extract pulls draft-guide facts out of plain text. Steps are condensed
// paraphrases of numbered/imperative lines — never verbatim copies.
func extract(text string) facts {
	var f facts
	seenTool := map[string]bool{}
	seenPart := map[string]bool{}
	seenStep := map[string]bool{}
	var lastPart *part

	for _, line := range strings.Split(text, "\n") {
		lower := strings.ToLower(line)

		// Ordered steps: numbered lines or imperative sentences, condensed.
		if m := reStepLine.FindStringSubmatch(line); m != nil || reImperative.MatchString(line) {
			s := line
			if m != nil {
				s = m[2]
			}
			s = condense(s)
			// Imperative hits without function words are usually nav links
			// or list titles ("Bleed Car Brakes"), not procedure text.
			if len(s) >= 8 && reFunc.MatchString(s) && !seenStep[s] {
				seenStep[s] = true
				f.steps = append(f.steps, s)
			}
		}

		for _, tw := range toolWords {
			if m := tw.re.FindString(lower); m != "" {
				name := tw.re.ReplaceAllString(m, tw.name)
				if !seenTool[name] {
					seenTool[name] = true
					f.tools = append(f.tools, name)
				}
			}
		}

		for _, pw := range partWords {
			if m := pw.FindStringSubmatch(line); m != nil {
				name := strings.ToLower(strings.TrimSpace(m[1]))
				key := strings.TrimSuffix(name, "s")
				if !seenPart[key] {
					seenPart[key] = true
					f.parts = append(f.parts, part{Name: name})
				}
			}
		}

		if m := rePartNumber.FindStringSubmatch(line); m != nil && len(f.parts) > 0 {
			lastPart = &f.parts[len(f.parts)-1]
			lastPart.PartNumber = m[1]
		}

		if m := reCost.FindStringSubmatch(line); m != nil && len(f.parts) > 0 {
			var dollars float64
			fmt.Sscanf(m[1], "%f", &dollars)
			cents := int(dollars * 100)
			lastPart = &f.parts[len(f.parts)-1]
			if lastPart.EstCostLow == 0 {
				lastPart.EstCostLow = cents
			}
			if cents > lastPart.EstCostHigh {
				lastPart.EstCostHigh = cents
			}
		}

		if reCaution.MatchString(line) {
			c := condense(line)
			if len(c) >= 12 && !seenStep["c:"+c] {
				seenStep["c:"+c] = true
				f.cautions = append(f.cautions, c)
			}
		}
		if reTradeoff.MatchString(line) {
			t := condense(line)
			if len(t) >= 12 && !seenStep["t:"+t] {
				seenStep["t:"+t] = true
				f.tradeoffs = append(f.tradeoffs, t)
			}
		}
	}

	// Torque mentions appended as cautions so the curator sees them.
	for _, m := range reTorque.FindAllString(text, 8) {
		f.cautions = append(f.cautions, "Torque spec mentioned in source: "+strings.TrimSpace(m))
	}
	return f
}

// condense normalises a candidate step into a short imperative fragment: trims
// quoting/punctuation, lowercases the first word if it is not a unit, and caps
// the length so it reads as an outline entry rather than copied prose.
func condense(s string) string {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, `"“”'`)
	s = reCite.ReplaceAllString(s, "")
	// Keep the first clause only, capped short — an outline fragment for the
	// curator to rewrite, never a copied sentence.
	if i := strings.IndexAny(s, ";:—"); i > 0 {
		s = s[:i]
	}
	if len(s) > 72 {
		s = strings.TrimSpace(s[:72])
		if i := strings.LastIndex(s, " "); i > 20 {
			s = s[:i]
		}
		s += "…"
	}
	return strings.TrimSpace(s)
}
