package tasks

import (
	"context"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"localllm/internal/schema"
)

// Limits of a summary. They hold the output limit by construction: the code
// cuts the fields, it does not trust the model for the length.
const (
	maxSummaryChars  = 2000
	maxKeyPoints     = 10
	maxKeyPointChars = 300
	maxReduceRounds  = 6
)

var confidenceValues = []string{"low", "medium", "high"}

// Summary is the result of the summarize task with the style "text".
type Summary struct {
	Summary    string   `json:"summary"`
	KeyPoints  []string `json:"key_points"`
	Confidence string   `json:"confidence"`
}

var summarySchema = mustSchema(schema.Object(map[string]*jsonschema.Schema{
	"summary":    schema.String(),
	"key_points": schema.Array(schema.String()),
	"confidence": schema.Enum(confidenceValues...),
}))

func mustSchema(s *jsonschema.Schema) *schema.Schema {
	built, err := schema.New(s)
	if err != nil {
		panic(err)
	}
	return built
}

// summarize makes one summary for each chunk, then combines the summaries
// until one is left.
func (c *call) summarize(ctx context.Context) (any, *failure) {
	instructions := prompt("summarize")
	if c.req.Focus != "" {
		instructions += "\nFocus of the summary: " + c.req.Focus
	}

	var parts []Summary
	for _, ch := range c.chunks {
		value, f := c.askJSON(ctx, c.userPrompt(instructions, c.label(ch), ch.text), summarySchema)
		if f != nil {
			return nil, f
		}
		parts = append(parts, toSummary(value))
	}

	for round := 0; len(parts) > 1; round++ {
		if round == maxReduceRounds {
			return nil, fail(StatusError, "reduce_failed", "the partial summaries did not combine into one")
		}
		var next []Summary
		for _, group := range groupParts(parts, c.cfg.ChunkChars) {
			if len(group) == 1 {
				next = append(next, group[0])
				continue
			}
			value, f := c.askJSON(ctx, c.userPrompt(prompt("summarize_reduce"), "Input: summaries of the parts", renderParts(group)), summarySchema)
			if f != nil {
				return nil, f
			}
			next = append(next, toSummary(value))
		}
		parts = next
	}
	return parts[0], nil
}

func toSummary(value map[string]any) Summary {
	s := Summary{
		Summary:    clipMark(stringOf(value["summary"]), maxSummaryChars),
		Confidence: stringOf(value["confidence"]),
	}
	s.KeyPoints = stringsOf(value["key_points"], maxKeyPoints, maxKeyPointChars)
	if s.KeyPoints == nil {
		s.KeyPoints = []string{}
	}
	return s
}

// groupParts puts consecutive summaries into groups that fit in one chunk.
// A group has two summaries or more when that is possible, so each round
// makes the list shorter.
func groupParts(parts []Summary, maxChars int) [][]Summary {
	var groups [][]Summary
	var current []Summary
	size := 0
	for _, part := range parts {
		partSize := len(renderParts([]Summary{part}))
		if len(current) >= 2 && size+partSize > maxChars {
			groups = append(groups, current)
			current, size = nil, 0
		}
		current = append(current, part)
		size += partSize
	}
	if len(current) > 0 {
		groups = append(groups, current)
	}
	return groups
}

func renderParts(parts []Summary) string {
	var b strings.Builder
	for i, part := range parts {
		fmt.Fprintf(&b, "Part %d (confidence %s):\n%s\n", i+1, part.Confidence, part.Summary)
		for _, point := range part.KeyPoints {
			b.WriteString("- " + point + "\n")
		}
		b.WriteString("\n")
	}
	return b.String()
}

func stringOf(value any) string {
	s, _ := value.(string)
	return s
}

func intOf(value any) int {
	n, _ := value.(float64)
	return int(n)
}

// stringsOf returns the text items of a list: no empty items, no
// duplicates, maxItems at most, each cut to maxChars.
func stringsOf(value any, maxItems, maxChars int) []string {
	items, _ := value.([]any)
	var out []string
	seen := map[string]bool{}
	for _, item := range items {
		text := clipMark(stringOf(item), maxChars)
		key := strings.ToLower(text)
		if text == "" || seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, text)
		if len(out) == maxItems {
			break
		}
	}
	return out
}
