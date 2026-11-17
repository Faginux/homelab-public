// Package audit writes one JSON line for each call of localllm (layer L10 of
// the plan). A record has metadata only: paths, hashes, sizes, counts,
// durations and the status. It never has input text or model output.
package audit

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

const (
	dayLayout  = "2006-01-02"
	filePrefix = "audit-"
	fileSuffix = ".jsonl"
)

// Only the files of this package have this name. Prune removes nothing else.
var fileName = regexp.MustCompile(`^audit-(\d{4}-\d{2}-\d{2})\.jsonl$`)

// Input identifies one input file of a call.
type Input struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256,omitempty"`
	Bytes  int64  `json:"bytes"`
}

// Entry is one audit record.
type Entry struct {
	Time        string  `json:"time"`
	Mode        string  `json:"mode"`
	Task        string  `json:"task"`
	Status      string  `json:"status"`
	Reason      string  `json:"reason,omitempty"`
	Model       string  `json:"model,omitempty"`
	Digest      string  `json:"digest,omitempty"`
	Inputs      []Input `json:"inputs,omitempty"`
	InputBytes  int64   `json:"input_bytes"`
	OutputBytes int64   `json:"output_bytes"`
	Chunks      int     `json:"chunks,omitempty"`
	Retries     int     `json:"retries,omitempty"`
	// RawModelInput is true when the model got the input with no
	// redaction. RedactionsIn then counts the values that the rules found,
	// not values that they removed.
	RawModelInput bool           `json:"raw_model_input,omitempty"`
	RedactionsIn  map[string]int `json:"redactions_in,omitempty"`
	RedactionsOut map[string]int `json:"redactions_out,omitempty"`
	PromptTokens  int            `json:"prompt_tokens"`
	OutputTokens  int            `json:"output_tokens"`
	DurationMs    int64          `json:"duration_ms"`
	StagingFile   string         `json:"staging_file,omitempty"`
}

// Log writes the records of one directory, one file for each day.
type Log struct {
	dir           string
	retentionDays int
	now           func() time.Time
}

// New makes a log. The directory is made at the first write.
func New(dir string, retentionDays int) *Log {
	return &Log{dir: dir, retentionDays: retentionDays, now: time.Now}
}

// Write adds one record to the file of the current day.
func (l *Log) Write(entry Entry) error {
	now := l.now()
	entry.Time = now.Format(time.RFC3339)
	line, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("audit: encode: %w", err)
	}
	if err := os.MkdirAll(l.dir, 0o755); err != nil {
		return fmt.Errorf("audit: make directory: %w", err)
	}
	path := filepath.Join(l.dir, filePrefix+now.Format(dayLayout)+fileSuffix)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("audit: open: %w", err)
	}
	_, writeErr := f.Write(append(line, '\n'))
	if err := errors.Join(writeErr, f.Close()); err != nil {
		return fmt.Errorf("audit: write: %w", err)
	}
	return nil
}

// Prune removes the audit files that are older than the retention time. It
// returns the number of removed files.
func (l *Log) Prune() (int, error) {
	files, err := listFiles(l.dir)
	if err != nil {
		return 0, err
	}
	today := l.now().Format(dayLayout)
	limit, err := time.Parse(dayLayout, today)
	if err != nil {
		return 0, fmt.Errorf("audit: %w", err)
	}
	limit = limit.AddDate(0, 0, -l.retentionDays)

	removed := 0
	for _, file := range files {
		if !file.day.Before(limit) {
			continue
		}
		if err := os.Remove(file.path); err != nil {
			return removed, fmt.Errorf("audit: remove old file: %w", err)
		}
		removed++
	}
	return removed, nil
}

// Read returns the records from the given day to the current day, in the
// sequence of the files. A line that is not valid JSON is an error.
func Read(dir string, since time.Time) ([]Entry, error) {
	files, err := listFiles(dir)
	if err != nil {
		return nil, err
	}
	first, err := time.Parse(dayLayout, since.Format(dayLayout))
	if err != nil {
		return nil, fmt.Errorf("audit: %w", err)
	}
	var entries []Entry
	for _, file := range files {
		if file.day.Before(first) {
			continue
		}
		fileEntries, err := readFile(file.path)
		if err != nil {
			return nil, err
		}
		entries = append(entries, fileEntries...)
	}
	return entries, nil
}

type datedFile struct {
	path string
	day  time.Time
}

func listFiles(dir string) ([]datedFile, error) {
	items, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("audit: list directory: %w", err)
	}
	var files []datedFile
	for _, item := range items {
		match := fileName.FindStringSubmatch(item.Name())
		if match == nil || !item.Type().IsRegular() {
			continue
		}
		day, err := time.Parse(dayLayout, match[1])
		if err != nil {
			continue
		}
		files = append(files, datedFile{path: filepath.Join(dir, item.Name()), day: day})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].day.Before(files[j].day) })
	return files, nil
}

func readFile(path string) ([]Entry, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("audit: open: %w", err)
	}
	defer f.Close()

	var entries []Entry
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for line := 1; scanner.Scan(); line++ {
		if len(scanner.Bytes()) == 0 {
			continue
		}
		var entry Entry
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			return nil, fmt.Errorf("audit: %s line %d: %w", filepath.Base(path), line, err)
		}
		entries = append(entries, entry)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("audit: read %s: %w", filepath.Base(path), err)
	}
	return entries, nil
}
