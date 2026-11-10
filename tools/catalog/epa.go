package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/csv"
	"fmt"
	"io"
	"log"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	epaVehiclesURL = "https://www.fueleconomy.gov/feg/epadata/vehicles.csv.zip"
	epaTestCarPage = "https://www.epa.gov/compliance-and-fuel-economy-data/data-cars-used-testing-fuel-economy"
	// Test car lists before 2010 name columns by code and carry no make; they are skipped.
	firstTestCarYear = 2010
)

// epaRow is one line of fueleconomy.gov vehicles.csv.
type epaRow struct {
	Year      int
	Make      string // curated display name
	Model     string
	BaseModel string
	Displ     float64 // 0 when absent (electric)
	Cyl       int
	Drive     string
	Trany     string
	Turbo     bool
	Super     bool
	EngDscr   string
	ATVType   string
}

func loadEPA(ctx context.Context, f *fetcher) ([]epaRow, error) {
	b, err := f.get(ctx, epaVehiclesURL, "epa/vehicles.csv.zip")
	if err != nil {
		return nil, err
	}
	zr, err := zip.NewReader(bytes.NewReader(b), int64(len(b)))
	if err != nil {
		return nil, err
	}
	var body io.ReadCloser
	for _, zf := range zr.File {
		if strings.HasSuffix(strings.ToLower(zf.Name), ".csv") {
			if body, err = zf.Open(); err != nil {
				return nil, err
			}
			break
		}
	}
	if body == nil {
		return nil, fmt.Errorf("vehicles.csv not in zip")
	}
	defer body.Close()

	byEPAName := map[string]string{}
	for _, m := range curatedMakes {
		if m.Bike {
			continue
		}
		byEPAName[strings.ToLower(m.Name)] = m.Name
		for _, alias := range m.EPA {
			byEPAName[strings.ToLower(alias)] = m.Name
		}
	}

	r := csv.NewReader(latin1(body))
	r.FieldsPerRecord = -1
	header, err := r.Read()
	if err != nil {
		return nil, err
	}
	col := columns(header)
	var out []epaRow
	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		get := func(name string) string { return field(rec, col, name) }
		mk, ok := byEPAName[strings.ToLower(get("make"))]
		if !ok {
			continue
		}
		year, _ := strconv.Atoi(get("year"))
		displ, _ := strconv.ParseFloat(get("displ"), 64)
		cyl, _ := strconv.Atoi(get("cylinders"))
		out = append(out, epaRow{
			Year: year, Make: mk, Model: strings.TrimSpace(get("model")), BaseModel: strings.TrimSpace(get("baseModel")),
			Displ: displ, Cyl: cyl, Drive: get("drive"), Trany: get("trany"),
			Turbo: get("tCharger") == "T", Super: get("sCharger") == "S",
			EngDscr: get("eng_dscr"), ATVType: get("atvType"),
		})
	}
	return out, nil
}

// testCar is one row of an EPA annual test car list: the rated figures the plan's
// performance model needs and vehicles.csv lacks.
type testCar struct {
	Year  int
	Make  string // lower case
	Model string
	Displ float64
	Cyl   int
	Trans string // "manual" or "automatic"
	Gears int
	Drive string
	HP    int
	ETW   int // equivalent test weight, binned
	Axle  float64
}

var testCarLink = regexp.MustCompile(`href="([^"]*/(\d\d)-?(?:tstcar|testcar)[^"]*\.(?:csv|xlsx))"`)

func loadTestCars(ctx context.Context, f *fetcher) ([]testCar, error) {
	page, err := f.get(ctx, epaTestCarPage, "epa/testcar.html")
	if err != nil {
		return nil, err
	}
	links := map[int]string{}
	for _, m := range testCarLink.FindAllStringSubmatch(string(page), -1) {
		yy, _ := strconv.Atoi(m[2])
		year := 2000 + yy
		if year < firstTestCarYear || strings.Contains(m[1], "laterelease") {
			continue
		}
		links[year] = m[1]
	}
	years := make([]int, 0, len(links))
	for y := range links {
		years = append(years, y)
	}
	sort.Ints(years)
	var out []testCar
	for _, y := range years {
		u := links[y]
		name := fmt.Sprintf("epa/testcar-%d%s", y, u[strings.LastIndex(u, "."):])
		b, err := f.get(ctx, u, name)
		if err != nil {
			return nil, err
		}
		var rows [][]string
		if strings.HasSuffix(u, ".xlsx") {
			rows, err = readXLSX(b)
		} else {
			cr := csv.NewReader(latin1(bytes.NewReader(b)))
			cr.FieldsPerRecord = -1
			cr.LazyQuotes = true
			rows, err = cr.ReadAll()
		}
		if err != nil {
			return nil, fmt.Errorf("test cars %d: %w", y, err)
		}
		n := len(out)
		out = append(out, parseTestCars(rows)...)
		log.Printf("test cars %d: %d rows", y, len(out)-n)
	}
	return out, nil
}

func parseTestCars(rows [][]string) []testCar {
	if len(rows) == 0 {
		return nil
	}
	col := columns(rows[0])
	if _, ok := col["rated horsepower"]; !ok {
		return nil
	}
	var out []testCar
	for _, rec := range rows[1:] {
		get := func(name string) string { return field(rec, col, name) }
		year, _ := strconv.Atoi(get("model year"))
		hp, _ := strconv.Atoi(strings.Split(get("rated horsepower"), ".")[0])
		if year == 0 || hp == 0 {
			continue
		}
		displ, _ := strconv.ParseFloat(get("test veh displacement (l)"), 64)
		cyl, _ := strconv.Atoi(get("# of cylinders and rotors"))
		gears, _ := strconv.Atoi(get("# of gears"))
		etw, _ := strconv.Atoi(strings.Split(get("equivalent test weight (lbs.)"), ".")[0])
		axle, _ := strconv.ParseFloat(get("axle ratio"), 64)
		trans := "automatic"
		if get("tested transmission type") == "Manual" {
			trans = "manual"
		}
		out = append(out, testCar{
			Year: year, Make: strings.ToLower(strings.TrimSpace(get("represented test veh make"))),
			Model: strings.TrimSpace(get("represented test veh model")), Displ: displ, Cyl: cyl,
			Trans: trans, Gears: gears, Drive: get("drive system description"), HP: hp, ETW: etw, Axle: axle,
		})
	}
	return out
}

func columns(header []string) map[string]int {
	col := map[string]int{}
	for i, h := range header {
		col[strings.ToLower(strings.TrimSpace(strings.TrimPrefix(h, "\ufeff")))] = i
	}
	return col
}

func field(rec []string, col map[string]int, name string) string {
	i, ok := col[strings.ToLower(name)]
	if !ok || i >= len(rec) {
		return ""
	}
	return strings.TrimSpace(rec[i])
}

// latin1 decodes ISO-8859-1 (both EPA files use it) into UTF-8.
func latin1(r io.Reader) io.Reader {
	b, err := io.ReadAll(r)
	if err != nil {
		return bytes.NewReader(nil)
	}
	var out bytes.Buffer
	out.Grow(len(b))
	for _, c := range b {
		out.WriteRune(rune(c))
	}
	return &out
}
