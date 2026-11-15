package tasks

import (
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"localllm/internal/config"
)

// Limits of the request fields. They keep the prompt small and keep caller
// text out of the schema.
const (
	maxFocusChars       = 200
	maxFields           = 20
	maxFieldDescription = 200
	minLabels           = 2
	maxLabels           = 20
	maxClassifyDocs     = 50
)

// Field types of the extract task.
const (
	FieldString = "string"
	FieldList   = "list"
)

var (
	fieldNamePattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,39}$`)
	labelPattern     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$`)
)

// draftKinds gives the file extension and the comment form for each kind of
// draft.
var draftKinds = map[string]struct {
	ext    string
	header string
}{
	"markdown":   {".md", "<!-- %s -->\n"},
	"powershell": {".ps1", "# %s\n"},
	"yaml":       {".yml", "# %s\n"},
	"text":       {".txt", ""},
}

func badRequest(format string, args ...any) *failure {
	return fail(StatusBadRequest, "bad_request", fmt.Sprintf(format, args...))
}

func (c *call) validate() *failure {
	req := &c.req
	switch req.Tier {
	case "", config.TierS, config.TierM:
	default:
		return badRequest("the tier must be %q or %q", config.TierS, config.TierM)
	}
	if req.Inline && utf8.RuneCountInString(req.Text) > c.cfg.MaxInlineChars {
		return badRequest("inline text has a limit of %d characters: write the text to a file in an allowed root and give the path", c.cfg.MaxInlineChars)
	}
	hasInput := len(req.Paths) > 0 || req.Text != ""

	switch req.Task {
	case config.TaskSummarize:
		if req.Style == "" {
			req.Style = StyleText
		}
		if req.Style != StyleText && req.Style != StyleLog {
			return badRequest("the style must be %q or %q", StyleText, StyleLog)
		}
		if utf8.RuneCountInString(req.Focus) > maxFocusChars || strings.ContainsAny(req.Focus, "\r\n") {
			return badRequest("the focus must be one line of %d characters at most", maxFocusChars)
		}
	case config.TaskExtract:
		if f := validateFields(req.Fields); f != nil {
			return f
		}
	case config.TaskClassify:
		if f := validateLabels(req.Labels); f != nil {
			return f
		}
	case config.TaskDraft:
		if strings.TrimSpace(req.Instruction) == "" {
			return badRequest("the instruction is necessary")
		}
		if utf8.RuneCountInString(req.Instruction) > c.cfg.MaxInlineChars {
			return badRequest("the instruction has a limit of %d characters", c.cfg.MaxInlineChars)
		}
		if _, ok := draftKinds[req.Kind]; !ok {
			return badRequest("the kind must be markdown, powershell, yaml or text")
		}
		return nil // a draft needs no input
	default:
		return badRequest("unknown task %q", req.Task)
	}
	if !hasInput {
		return badRequest("the call needs paths or text")
	}
	return nil
}

func validateFields(fields []Field) *failure {
	if len(fields) == 0 || len(fields) > maxFields {
		return badRequest("the call needs 1 to %d fields", maxFields)
	}
	seen := map[string]bool{}
	for _, field := range fields {
		switch {
		case !fieldNamePattern.MatchString(field.Name):
			return badRequest("a field name must be lower case letters, digits and underscores, 40 characters at most")
		case seen[field.Name]:
			return badRequest("the field %q is in the list two times", field.Name)
		case field.Type != FieldString && field.Type != FieldList:
			return badRequest("the type of the field %q must be %q or %q", field.Name, FieldString, FieldList)
		case utf8.RuneCountInString(field.Description) > maxFieldDescription || strings.ContainsAny(field.Description, "\r\n"):
			return badRequest("the description of the field %q must be one line of %d characters at most", field.Name, maxFieldDescription)
		}
		seen[field.Name] = true
	}
	return nil
}

func validateLabels(labels []string) *failure {
	if len(labels) < minLabels || len(labels) > maxLabels {
		return badRequest("the call needs %d to %d labels", minLabels, maxLabels)
	}
	seen := map[string]bool{}
	for _, label := range labels {
		if !labelPattern.MatchString(label) {
			return badRequest("a label must be letters, digits, spaces, dots, hyphens and underscores, 40 characters at most")
		}
		if seen[label] {
			return badRequest("the label %q is in the list two times", label)
		}
		seen[label] = true
	}
	return nil
}
