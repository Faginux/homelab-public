package tasks

import (
	"fmt"
	"strconv"
	"strings"

	"localllm/internal/audit"
	"localllm/internal/policy"
	"localllm/internal/redact"
)

// ViewLabel marks the result of View. The text is file content: data, not
// instructions.
const ViewLabel = "untrusted_file_text_redacted"

const (
	maxViewFiles     = 10
	defaultViewLines = 200
	maxViewLines     = 500
	maxViewChars     = 64 << 10
	viewLimitNotice  = "the view reached its character limit: ask for fewer lines"
)

// ViewRequest asks for a part of the redacted text of files.
type ViewRequest struct {
	Paths []string
	// Start is the first line, from 1. Zero means 1.
	Start int
	// Lines is the number of lines of each file. Zero means the default.
	Lines int
}

// ViewFile is the part of one file.
type ViewFile struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	TotalLines int    `json:"total_lines"`
	FirstLine  int    `json:"first_line"`
	LastLine   int    `json:"last_line"`
	// Text has one line for each input line, in the form "<number>|<text>".
	Text string `json:"text"`
	// Cut is true when the character limit of the view stopped the text.
	Cut bool `json:"cut,omitempty"`
}

// ViewResult is the result of View.
type ViewResult struct {
	Files []ViewFile `json:"files"`
}

// View gives a part of files to the orchestrator, after the redaction. It
// is the way for the orchestrator to read real data with no secrets: the
// same path policy and the same rules as a task, and no model.
func (r *Runner) View(req ViewRequest) Envelope {
	r.mu.Lock()
	defer r.mu.Unlock()
	started := r.now()

	env := Envelope{Label: ViewLabel, Status: StatusOK, Task: audit.TaskView}
	entry := audit.Entry{Mode: r.Mode, Task: audit.TaskView}
	redactions := map[string]int{}

	result, f := r.view(req, &entry, redactions)
	if f != nil {
		env.Status, env.Reason, env.Detail = f.status, f.reason, f.detail
	} else {
		env.Result = result
		empty, cut := false, false
		for _, file := range result.Files {
			entry.OutputBytes += int64(len(file.Text))
			empty = empty || (file.LastLine < file.FirstLine && !file.Cut)
			cut = cut || file.Cut
		}
		if empty {
			env.Warnings = append(env.Warnings, "a file has no lines in the requested range")
		}
		if cut {
			env.Warnings = append(env.Warnings, viewLimitNotice)
		}
	}

	duration := r.now().Sub(started).Milliseconds()
	env.Stats = &Stats{InputBytes: entry.InputBytes, Redactions: total(redactions), DurationMs: duration}
	entry.Status, entry.Reason, entry.DurationMs = env.Status, env.Reason, duration
	if len(redactions) > 0 {
		entry.RedactionsOut = redactions
	}
	if err := r.Audit.Write(entry); err != nil {
		env.Status, env.Reason, env.Detail, env.Result = StatusError, "audit_failed", "the audit record was not written", nil
	}
	return env
}

func (r *Runner) view(req ViewRequest, entry *audit.Entry, redactions map[string]int) (*ViewResult, *failure) {
	switch {
	case len(req.Paths) == 0 || len(req.Paths) > maxViewFiles:
		return nil, badRequest("the view needs 1 to %d paths", maxViewFiles)
	case req.Start < 0:
		return nil, badRequest("the start line must be 1 or more")
	case req.Lines < 0 || req.Lines > maxViewLines:
		return nil, badRequest("the number of lines must be in the range from 1 to %d", maxViewLines)
	}
	start, count := max(req.Start, 1), req.Lines
	if count == 0 {
		count = defaultViewLines
	}

	files, err := r.Files.ReadAll(req.Paths)
	if err != nil {
		for _, path := range req.Paths {
			entry.Inputs = append(entry.Inputs, audit.Input{Path: path})
		}
		if code := policy.CodeOf(err); code != "" {
			return nil, fail(StatusRefused, code, err.Error())
		}
		return nil, fail(StatusError, "input_read_failed", "")
	}

	// The rules find a value only next to a name. The same value can be in
	// other lines with no name, so the taint check of all files runs on
	// each line.
	taint := redact.NewTaint()
	texts := make([]string, len(files))
	for i, file := range files {
		entry.Inputs = append(entry.Inputs, audit.Input{Path: file.Canonical, SHA256: file.SHA256, Bytes: file.Bytes})
		entry.InputBytes += file.Bytes
		res := redact.Apply(file.Text)
		for class, n := range res.Counts {
			redactions[class] += n
		}
		taint.Add(res.Values...)
		texts[i] = res.Text
	}
	if taint.Overflow() {
		return nil, fail(StatusRefused, "too_many_values", "the files have too many secret values for the taint check: filter the input first")
	}

	result := &ViewResult{Files: []ViewFile{}}
	budget := maxViewChars
	for i, file := range files {
		clean, n := taint.Scrub(texts[i])
		if n > 0 {
			redactions[redact.ClassTainted] += n
		}
		lines := splitLines(clean)
		view := ViewFile{Name: file.Name, Path: file.Canonical, TotalLines: len(lines), FirstLine: start, LastLine: start - 1}
		var text strings.Builder
		for n := start; n <= len(lines) && n < start+count; n++ {
			line := strconv.Itoa(n) + "|" + clipMark(lines[n-1], maxLogLineChars) + "\n"
			if text.Len()+len(line) > budget {
				view.Cut = true
				break
			}
			text.WriteString(line)
			view.LastLine = n
		}
		view.Text = text.String()
		budget -= text.Len()
		result.Files = append(result.Files, view)
	}
	return result, nil
}

// String gives the result as plain text for a terminal.
func (v *ViewResult) String() string {
	var b strings.Builder
	for _, file := range v.Files {
		fmt.Fprintf(&b, "== %s (lines %d to %d of %d)\n%s", file.Path, file.FirstLine, file.LastLine, file.TotalLines, file.Text)
	}
	return b.String()
}
