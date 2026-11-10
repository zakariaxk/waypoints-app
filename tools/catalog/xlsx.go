package main

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// readXLSX returns the first worksheet of an .xlsx file as rows of strings. It handles the
// subset the EPA test car files use: shared strings, inline strings, and plain numbers.
func readXLSX(b []byte) ([][]string, error) {
	zr, err := zip.NewReader(bytes.NewReader(b), int64(len(b)))
	if err != nil {
		return nil, err
	}
	files := map[string]*zip.File{}
	for _, f := range zr.File {
		files[f.Name] = f
	}
	var shared []string
	if f, ok := files["xl/sharedStrings.xml"]; ok {
		if shared, err = readShared(f); err != nil {
			return nil, err
		}
	}
	sheet, ok := files["xl/worksheets/sheet1.xml"]
	if !ok {
		return nil, fmt.Errorf("xlsx: no sheet1")
	}
	rc, err := sheet.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()

	type cell struct {
		Ref    string `xml:"r,attr"`
		Type   string `xml:"t,attr"`
		Value  string `xml:"v"`
		Inline string `xml:"is>t"`
	}
	type row struct {
		Cells []cell `xml:"c"`
	}
	dec := xml.NewDecoder(rc)
	var rows [][]string
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		se, ok := tok.(xml.StartElement)
		if !ok || se.Name.Local != "row" {
			continue
		}
		var r row
		if err := dec.DecodeElement(&r, &se); err != nil {
			return nil, err
		}
		var out []string
		for _, c := range r.Cells {
			i := colIndex(c.Ref)
			for len(out) <= i {
				out = append(out, "")
			}
			switch c.Type {
			case "s":
				n, _ := strconv.Atoi(c.Value)
				if n < len(shared) {
					out[i] = shared[n]
				}
			case "inlineStr":
				out[i] = c.Inline
			default:
				out[i] = c.Value
			}
		}
		rows = append(rows, out)
	}
	return rows, nil
}

func readShared(f *zip.File) ([]string, error) {
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	var sst struct {
		Items []struct {
			T    string   `xml:"t"`
			Runs []string `xml:"r>t"`
		} `xml:"si"`
	}
	if err := xml.NewDecoder(rc).Decode(&sst); err != nil {
		return nil, err
	}
	out := make([]string, len(sst.Items))
	for i, it := range sst.Items {
		out[i] = it.T + strings.Join(it.Runs, "")
	}
	return out, nil
}

// colIndex turns "AB12" into 27.
func colIndex(ref string) int {
	n := 0
	for _, r := range ref {
		if r < 'A' || r > 'Z' {
			break
		}
		n = n*26 + int(r-'A'+1)
	}
	return n - 1
}
