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
	maxLabelDescription = 200
	// maxLabelDescriptions is the limit of all label descriptions of one
	// call. The descriptions go into each prompt of the call.
	maxLabelDescriptions = 2000
	maxClassifyDocs      = 50
	// minClassifyInput is the smallest part of a document that classify
	// sends. If the label descriptions leave less space, the call stops.
	minClassifyInput = 1000
)

// Label is one permitted label of the classify task. The caller writes it
// as "name" or "name: description". Only the name goes into the schema, so
// the result is always a name. The description goes into the prompt.
type Label struct {
	Name        string
	Description string
}

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
		labels, f := parseLabels(req.Labels)
		if f != nil {
			return f
		}
		c.labels = labels
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

// parseLabels reads the labels of a classify call. The text before the
// first colon is the name. The text after it is an optional description.
// A name cannot have a colon, so the split is not ambiguous.
func parseLabels(raw []string) ([]Label, *failure) {
	if len(raw) < minLabels || len(raw) > maxLabels {
		return nil, badRequest("the call needs %d to %d labels", minLabels, maxLabels)
	}
	labels := make([]Label, 0, len(raw))
	seen := map[string]bool{}
	total := 0
	for _, text := range raw {
		name, description, _ := strings.Cut(text, ":")
		name = strings.TrimSpace(name)
		description = strings.TrimSpace(description)
		switch {
		case !labelPattern.MatchString(name):
			return nil, badRequest("a label name must be letters, digits, spaces, dots, hyphens and underscores, 40 characters at most")
		case seen[name]:
			return nil, badRequest("the label %q is in the list two times", name)
		case utf8.RuneCountInString(description) > maxLabelDescription || strings.ContainsAny(description, "\r\n"):
			return nil, badRequest("the description of the label %q must be one line of %d characters at most", name, maxLabelDescription)
		}
		total += utf8.RuneCountInString(description)
		seen[name] = true
		labels = append(labels, Label{Name: name, Description: description})
	}
	if total > maxLabelDescriptions {
		return nil, badRequest("the label descriptions have %d characters, and the limit is %d", total, maxLabelDescriptions)
	}
	return labels, nil
}

// labelNames returns the names of the labels, in the order of the caller.
func labelNames(labels []Label) []string {
	names := make([]string, len(labels))
	for i, l := range labels {
		names[i] = l.Name
	}
	return names
}

// labelDescriptionChars is the size of all label descriptions in the
// prompt, with the separator of each one.
func labelDescriptionChars(labels []Label) int {
	n := 0
	for _, l := range labels {
		if l.Description != "" {
			n += utf8.RuneCountInString(l.Description) + len(": ")
		}
	}
	return n
}
