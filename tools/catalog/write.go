package main

import (
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE make (id INTEGER PRIMARY KEY, name TEXT NOT NULL, popular_rank INTEGER NOT NULL DEFAULT 0);
CREATE TABLE model (
	id INTEGER PRIMARY KEY, make_id INTEGER NOT NULL REFERENCES make(id), name TEXT NOT NULL,
	year_from INTEGER NOT NULL, year_to INTEGER NOT NULL
);
CREATE INDEX model_make ON model(make_id);
CREATE TABLE variant (
	id INTEGER PRIMARY KEY, model_id INTEGER NOT NULL REFERENCES model(id), year INTEGER NOT NULL,
	trim TEXT, engine TEXT, displacement_l REAL, cylinders INTEGER, aspiration TEXT, drive TEXT,
	transmission TEXT, hp INTEGER, torque_lbft INTEGER, weight_lb INTEGER, redline INTEGER,
	gears_json TEXT, spec_source TEXT
);
CREATE INDEX variant_model_year ON variant(model_id, year);
-- Contentless: rowid is variant.id; the text is "make model trim" plus aliases.
CREATE VIRTUAL TABLE variant_fts USING fts5(text, content='', detail='none', tokenize='unicode61 remove_diacritics 2');
`

func writeSQLite(path string, c *catalog, version string) error {
	if version == "" {
		version = time.Now().UTC().Format("2006.01.02")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	os.Remove(path)
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return err
	}
	defer db.Close()
	if _, err := db.Exec(schema); err != nil {
		return err
	}
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	for k, v := range map[string]string{"version": version, "schema": "1", "built_at": time.Now().UTC().Format(time.RFC3339)} {
		if _, err := tx.Exec(`INSERT INTO meta VALUES (?, ?)`, k, v); err != nil {
			return err
		}
	}
	makeID := map[string]int64{}
	for _, m := range c.makes {
		makeID[m.Name] = m.ID
		if _, err := tx.Exec(`INSERT INTO make VALUES (?, ?, ?)`, m.ID, m.Name, m.Popular); err != nil {
			return err
		}
	}
	for _, m := range c.models {
		if _, err := tx.Exec(`INSERT INTO model VALUES (?, ?, ?, ?, ?)`, m.ID, makeID[m.Make], m.Name, m.YearFrom, m.YearTo); err != nil {
			return err
		}
	}
	ins, err := tx.Prepare(`INSERT INTO variant VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return err
	}
	fts, err := tx.Prepare(`INSERT INTO variant_fts (rowid, text) VALUES (?, ?)`)
	if err != nil {
		return err
	}
	for _, v := range c.variants {
		if _, err := ins.Exec(v.ID, v.ModelID, v.Year, nullS(v.Trim), nullS(v.Engine), nullF(v.Displ), nullI(v.Cyl),
			nullS(v.Asp), nullS(v.Drive), nullS(v.Trans), nullI(v.HP), nullI(v.Torque), nullI(v.Weight),
			nullI(v.Redline), nullS(v.Gears), nullS(v.Source)); err != nil {
			return err
		}
		if _, err := fts.Exec(v.ID, ftsText(v.Make, v.Model, v.Trim)); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	for _, q := range []string{`INSERT INTO variant_fts(variant_fts) VALUES ('optimize')`, `ANALYZE`, `VACUUM`} {
		if _, err := db.Exec(q); err != nil {
			return fmt.Errorf("%s: %w", q, err)
		}
	}
	return nil
}

func nullS(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullI(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

func nullF(f float64) any {
	if f == 0 {
		return nil
	}
	return f
}

// compress writes LZFSE with macOS compression_tool, the same raw block format the app
// decodes with Foundation's NSData.decompressed(using: .lzfse).
func compress(in, out string) error {
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return err
	}
	cmd := exec.Command("compression_tool", "-encode", "-a", "lzfse", "-i", in, "-o", out)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("compression_tool (macOS only): %w", err)
	}
	return nil
}

func report(sqlitePath, out string) {
	db, err := sql.Open("sqlite", sqlitePath)
	if err != nil {
		fmt.Println(err)
		return
	}
	defer db.Close()
	fmt.Println("rows per table:")
	for _, t := range []string{"make", "model", "variant"} {
		var n int
		db.QueryRow(`SELECT count(*) FROM ` + t).Scan(&n)
		fmt.Printf("  %-8s %7d\n", t, n)
	}
	var modelYears, withHP, withTorque, ftsRows int
	db.QueryRow(`SELECT count(*) FROM (SELECT DISTINCT model_id, year FROM variant)`).Scan(&modelYears)
	db.QueryRow(`SELECT count(*) FROM variant WHERE hp IS NOT NULL`).Scan(&withHP)
	db.QueryRow(`SELECT count(*) FROM variant WHERE torque_lbft IS NOT NULL`).Scan(&withTorque)
	db.QueryRow(`SELECT count(*) FROM variant_fts`).Scan(&ftsRows)
	fmt.Printf("  %-8s %7d\n  model-years %d, variants with hp %d, with torque %d\n", "fts", ftsRows, modelYears, withHP, withTorque)

	fmt.Println("variants by spec source:")
	rows, _ := db.Query(`SELECT coalesce(spec_source, '-'), count(*) FROM variant GROUP BY 1 ORDER BY 2 DESC`)
	for rows.Next() {
		var s string
		var n int
		rows.Scan(&s, &n)
		fmt.Printf("  %-9s %7d\n", s, n)
	}
	rows.Close()

	fmt.Println("top 20 makes by model count:")
	rows, _ = db.Query(`SELECT make.name, count(*) FROM model JOIN make ON make.id = model.make_id GROUP BY make.id ORDER BY 2 DESC, 1 LIMIT 20`)
	for rows.Next() {
		var s string
		var n int
		rows.Scan(&s, &n)
		fmt.Printf("  %-16s %5d\n", s, n)
	}
	rows.Close()
	for _, p := range []string{sqlitePath, out} {
		if st, err := os.Stat(p); err == nil {
			fmt.Printf("%s: %.2f MB\n", p, float64(st.Size())/1e6)
		}
	}
}
