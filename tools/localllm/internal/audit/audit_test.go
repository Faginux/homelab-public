package audit

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func fixedClock(day string) func() time.Time {
	return func() time.Time {
		t, err := time.ParseInLocation("2006-01-02 15:04", day+" 10:30", time.Local)
		if err != nil {
			panic(err)
		}
		return t
	}
}

func TestWriteAndRead(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "logs")
	log := New(dir, 30)

	log.now = fixedClock("2026-11-14")
	first := Entry{
		Mode: "cli", Task: "summarize", Status: "ok", Model: "small:1",
		Inputs:       []Input{{Path: `C:\data\app.log`, SHA256: strings.Repeat("a", 64), Bytes: 40000}},
		InputBytes:   40000,
		OutputBytes:  800,
		RedactionsIn: map[string]int{"key_value": 2},
		PromptTokens: 9000, OutputTokens: 200, DurationMs: 4200, Chunks: 3,
	}
	if err := log.Write(first); err != nil {
		t.Fatalf("Write: %v", err)
	}
	log.now = fixedClock("2026-11-15")
	for _, e := range []Entry{
		{Mode: "mcp", Task: "classify", Status: "refused", Reason: "denied_name", Inputs: []Input{{Path: `C:\data\stack\server.key`}}},
		{Mode: "mcp", Task: "summarize", Status: "busy"},
	} {
		if err := log.Write(e); err != nil {
			t.Fatalf("Write: %v", err)
		}
	}

	names := dirNames(t, dir)
	want := []string{"audit-2026-11-14.jsonl", "audit-2026-11-15.jsonl"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("files = %v, want %v", names, want)
	}

	tests := []struct {
		name  string
		since string
		want  int
	}{
		{"all days", "2026-11-01", 3},
		{"last day only", "2026-11-15", 2},
		{"after the last day", "2026-11-16", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			since, _ := time.Parse(dayLayout, tt.since)
			entries, err := Read(dir, since)
			if err != nil {
				t.Fatalf("Read: %v", err)
			}
			if len(entries) != tt.want {
				t.Errorf("Read returned %d records, want %d", len(entries), tt.want)
			}
		})
	}

	entries, err := Read(dir, time.Time{})
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if entries[0].Time == "" || entries[0].Inputs[0].SHA256 != first.Inputs[0].SHA256 || entries[0].Chunks != 3 {
		t.Errorf("the first record changed in the file: %+v", entries[0])
	}
}

// The record must stay metadata only. A new field needs a decision, so this
// test fails when the set of JSON keys changes.
func TestEntryHasNoContentField(t *testing.T) {
	want := []string{
		"chunks", "digest", "duration_ms", "input_bytes", "inputs", "mode", "model",
		"output_bytes", "output_tokens", "prompt_tokens", "raw_model_input", "reason", "redactions_in",
		"redactions_out", "retries", "staging_file", "status", "task", "time",
	}
	var got []string
	typ := reflect.TypeOf(Entry{})
	for i := 0; i < typ.NumField(); i++ {
		got = append(got, strings.Split(typ.Field(i).Tag.Get("json"), ",")[0])
	}
	sort.Strings(got)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("the JSON keys of Entry changed:\n got %v\nwant %v", got, want)
	}

	wantInput := []string{"bytes", "path", "sha256"}
	var gotInput []string
	typ = reflect.TypeOf(Input{})
	for i := 0; i < typ.NumField(); i++ {
		gotInput = append(gotInput, strings.Split(typ.Field(i).Tag.Get("json"), ",")[0])
	}
	sort.Strings(gotInput)
	if !reflect.DeepEqual(gotInput, wantInput) {
		t.Errorf("the JSON keys of Input changed: got %v, want %v", gotInput, wantInput)
	}
}

func TestPrune(t *testing.T) {
	dir := t.TempDir()
	files := map[string]bool{ // name -> stays after the prune
		"audit-2026-10-15.jsonl":  false,
		"audit-2026-10-16.jsonl":  true, // exactly 30 days before the current day
		"audit-2026-11-15.jsonl":  true,
		"audit-2025-01-01.jsonl":  false,
		"server.log":              true,
		"server-1.log":            true,
		"audit-notes.jsonl":       true,
		"audit-2026-10-01.txt":    true,
		"xaudit-2026-10-01.jsonl": true,
	}
	for name := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// A directory with the name of an audit file is not an audit file.
	if err := os.Mkdir(filepath.Join(dir, "audit-2026-01-01.jsonl"), 0o755); err != nil {
		t.Fatal(err)
	}

	log := New(dir, 30)
	log.now = fixedClock("2026-11-15")
	removed, err := log.Prune()
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	if removed != 2 {
		t.Errorf("Prune removed %d files, want 2", removed)
	}
	for name, stays := range files {
		_, err := os.Stat(filepath.Join(dir, name))
		if exists := err == nil; exists != stays {
			t.Errorf("%s: exists = %v, want %v", name, exists, stays)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "audit-2026-01-01.jsonl")); err != nil {
		t.Error("Prune removed a directory")
	}
}

func TestPruneWithNoDirectory(t *testing.T) {
	log := New(filepath.Join(t.TempDir(), "missing"), 30)
	if removed, err := log.Prune(); err != nil || removed != 0 {
		t.Errorf("Prune = %d, %v, want 0 and no error", removed, err)
	}
}

func TestReadRefusesBadLine(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "audit-2026-11-15.jsonl"), []byte("{\"task\":\"x\"}\nnot json\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Read(dir, time.Time{})
	if err == nil || !strings.Contains(err.Error(), "line 2") {
		t.Errorf("Read error = %v, want an error for line 2", err)
	}
}

func TestSummarize(t *testing.T) {
	entries := []Entry{
		{Task: "summarize", Status: "ok", InputBytes: 40000, OutputBytes: 800, PromptTokens: 9000, OutputTokens: 200, RedactionsIn: map[string]int{"jwt": 1, "key_value": 2}},
		{Task: "summarize", Status: "ok", InputBytes: 400, OutputBytes: 900, PromptTokens: 100, OutputTokens: 220, RedactionsOut: map[string]int{"jwt": 1}},
		{Task: "classify", Status: "busy", InputBytes: 99999},
		{Task: "extract", Status: "refused", Reason: "outside_roots"},
	}
	got := Summarize(entries)
	want := Stats{
		Calls:         4,
		ByStatus:      map[string]int{"ok": 2, "busy": 1, "refused": 1},
		ByTask:        map[string]int{"summarize": 2, "classify": 1, "extract": 1},
		InputBytes:    40400,
		OutputBytes:   1700,
		PromptTokens:  9100,
		OutputTokens:  420,
		Redactions:    4,
		TokensNotRead: 9800,
	}
	if !reflect.DeepEqual(got, want) {
		gotJSON, _ := json.Marshal(got)
		wantJSON, _ := json.Marshal(want)
		t.Errorf("Summarize:\n got %s\nwant %s", gotJSON, wantJSON)
	}
}

func dirNames(t *testing.T, dir string) []string {
	t.Helper()
	items, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	var names []string
	for _, item := range items {
		names = append(names, item.Name())
	}
	sort.Strings(names)
	return names
}
