package tasks

import (
	"context"
	"regexp"
	"sort"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"localllm/internal/schema"
)

const (
	maxTopErrors      = 10
	maxErrorChars     = 300
	maxPatterns       = 10
	maxPatternChars   = 300
	maxNotableLines   = 10
	maxEvidenceChars  = 200
	invalidLineNotice = "the model gave line numbers that are not in its part of the log: they were removed"
)

// The code counts these lines itself. A parser counts better than a model.
var (
	errorLine   = regexp.MustCompile(`(?i)\b(?:error|err|fatal|panic|exception|critical|fail(?:ed|ure)?)\b`)
	warningLine = regexp.MustCompile(`(?i)\bwarn(?:ing)?\b`)
)

// LogError is one kind of error in a log.
type LogError struct {
	Message string `json:"message"`
	Count   int    `json:"count"`
	File    string `json:"file,omitempty"`
	Line    int    `json:"line,omitempty"`
	// Text is the real line of the input, not model output.
	Text string `json:"text,omitempty"`
}

// LineRef is a line that a person must read. Text is the real line.
type LineRef struct {
	File string `json:"file,omitempty"`
	Line int    `json:"line"`
	Text string `json:"text"`
}

// LogDigest is the result of the summarize task with the style "log".
type LogDigest struct {
	Lines        int        `json:"lines"`
	ErrorLines   int        `json:"error_lines"`
	WarningLines int        `json:"warning_lines"`
	TopErrors    []LogError `json:"top_errors"`
	Patterns     []string   `json:"patterns"`
	NotableLines []LineRef  `json:"notable_lines"`
}

var logSchema = mustSchema(schema.Object(map[string]*jsonschema.Schema{
	"top_errors": schema.Array(schema.Object(map[string]*jsonschema.Schema{
		"message": schema.String(),
		"count":   schema.Integer(),
		"line":    schema.Integer(),
	})),
	"patterns":      schema.Array(schema.String()),
	"notable_lines": schema.Array(schema.Integer()),
}))

// logDigest asks the model for the errors and patterns of each chunk and
// merges the answers in code. The model gives line numbers only: the code
// checks each number against the chunk and adds the real line text.
func (c *call) logDigest(ctx context.Context) (any, *failure) {
	digest := LogDigest{TopErrors: []LogError{}, Patterns: []string{}, NotableLines: []LineRef{}}
	manyFiles := len(c.docs) > 1
	for _, doc := range c.docs {
		digest.Lines += len(doc.lines)
		for _, line := range doc.lines {
			switch {
			case errorLine.MatchString(line):
				digest.ErrorLines++
			case warningLine.MatchString(line):
				digest.WarningLines++
			}
		}
	}

	byMessage := map[string]int{}
	seenPattern := map[string]bool{}
	seenLine := map[[2]int]bool{}
	for _, ch := range c.chunks {
		value, f := c.askJSON(ctx, c.userPrompt(prompt("log"), c.label(ch), ch.text), logSchema)
		if f != nil {
			return nil, f
		}
		doc := c.docs[ch.doc]
		file := ""
		if manyFiles {
			file = doc.name
		}
		inChunk := func(line int) bool { return line >= ch.firstLine && line <= ch.lastLine }

		items, _ := value["top_errors"].([]any)
		for _, item := range items {
			fields, _ := item.(map[string]any)
			message := clipMark(stringOf(fields["message"]), maxErrorChars)
			if message == "" {
				continue
			}
			// The count cannot be more than the lines of the chunk.
			count := min(max(intOf(fields["count"]), 1), ch.lastLine-ch.firstLine+1)
			entry := LogError{Message: message, Count: count}
			if line := intOf(fields["line"]); inChunk(line) {
				entry.File, entry.Line = file, line
				entry.Text = clipMark(doc.lines[line-1], maxEvidenceChars)
			} else {
				c.warn(invalidLineNotice)
			}
			key := strings.ToLower(message)
			if i, ok := byMessage[key]; ok {
				digest.TopErrors[i].Count += count
				continue
			}
			byMessage[key] = len(digest.TopErrors)
			digest.TopErrors = append(digest.TopErrors, entry)
		}

		for _, pattern := range stringsOf(value["patterns"], maxPatterns, maxPatternChars) {
			if key := strings.ToLower(pattern); !seenPattern[key] {
				seenPattern[key] = true
				digest.Patterns = append(digest.Patterns, pattern)
			}
		}

		lines, _ := value["notable_lines"].([]any)
		for _, item := range lines {
			line := intOf(item)
			if !inChunk(line) {
				c.warn(invalidLineNotice)
				continue
			}
			if key := [2]int{ch.doc, line}; !seenLine[key] {
				seenLine[key] = true
				digest.NotableLines = append(digest.NotableLines, LineRef{File: file, Line: line, Text: clipMark(doc.lines[line-1], maxEvidenceChars)})
			}
		}
	}

	// An error with a checked line comes before an error with no valid
	// line: the model cannot move an invented error to the top with a
	// large count.
	sort.SliceStable(digest.TopErrors, func(i, j int) bool {
		a, b := digest.TopErrors[i], digest.TopErrors[j]
		if (a.Line > 0) != (b.Line > 0) {
			return a.Line > 0
		}
		return a.Count > b.Count
	})
	digest.TopErrors = digest.TopErrors[:min(len(digest.TopErrors), maxTopErrors)]
	digest.Patterns = digest.Patterns[:min(len(digest.Patterns), maxPatterns)]
	digest.NotableLines = digest.NotableLines[:min(len(digest.NotableLines), maxNotableLines)]
	return digest, nil
}
