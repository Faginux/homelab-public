package tasks

import (
	"context"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"

	"localllm/internal/schema"
)

const (
	maxFieldChars    = 500
	maxListItems     = 50
	maxListItemChars = 300
)

// Extraction is the result of the extract task. A string field that is not
// in the input is an empty string. A list field is an empty list.
type Extraction struct {
	Fields map[string]any `json:"fields"`
}

// extract asks for the fields in each chunk and merges the answers in code:
// the first value that is not empty for a string, all values for a list.
func (c *call) extract(ctx context.Context) (any, *failure) {
	properties := map[string]*jsonschema.Schema{}
	var instructions strings.Builder
	instructions.WriteString(prompt("extract"))
	instructions.WriteString("\nFields:")
	for _, field := range c.req.Fields {
		if field.Type == FieldList {
			properties[field.Name] = schema.Array(schema.String())
		} else {
			properties[field.Name] = schema.String()
		}
		instructions.WriteString("\n- " + field.Name + " (" + field.Type + ")")
		if field.Description != "" {
			instructions.WriteString(": " + field.Description)
		}
	}
	sch, err := schema.New(schema.Object(properties))
	if err != nil {
		return nil, fail(StatusError, "schema_build_failed", "")
	}

	texts := map[string]string{}
	lists := map[string][]any{}
	for _, ch := range c.chunks {
		value, f := c.askJSON(ctx, c.userPrompt(instructions.String(), c.label(ch), ch.text), sch)
		if f != nil {
			return nil, f
		}
		for _, field := range c.req.Fields {
			if field.Type == FieldList {
				items, _ := value[field.Name].([]any)
				lists[field.Name] = append(lists[field.Name], items...)
			} else if texts[field.Name] == "" {
				texts[field.Name] = clipMark(stringOf(value[field.Name]), maxFieldChars)
			}
		}
	}

	result := Extraction{Fields: map[string]any{}}
	for _, field := range c.req.Fields {
		if field.Type == FieldList {
			items := stringsOf(lists[field.Name], maxListItems, maxListItemChars)
			if items == nil {
				items = []string{}
			}
			result.Fields[field.Name] = items
		} else {
			result.Fields[field.Name] = texts[field.Name]
		}
	}
	return result, nil
}

// Classification is the label of one document.
type Classification struct {
	File       string `json:"file"`
	Label      string `json:"label"`
	Confidence string `json:"confidence"`
}

// Classifications is the result of the classify task.
type Classifications struct {
	Results []Classification `json:"results"`
}

// classify gives one label from the list of the caller to each document.
// The schema permits only these labels, so the model cannot invent one.
func (c *call) classify(ctx context.Context) (any, *failure) {
	sch, err := schema.New(schema.Object(map[string]*jsonschema.Schema{
		"label":      schema.Enum(c.req.Labels...),
		"confidence": schema.Enum(confidenceValues...),
	}))
	if err != nil {
		return nil, fail(StatusError, "schema_build_failed", "")
	}
	instructions := prompt("classify") + "\nPermitted labels:\n- " + strings.Join(c.req.Labels, "\n- ")

	result := Classifications{Results: []Classification{}}
	for _, ch := range c.chunks {
		value, f := c.askJSON(ctx, c.userPrompt(instructions, c.label(ch), ch.text), sch)
		if f != nil {
			return nil, f
		}
		result.Results = append(result.Results, Classification{
			File:       c.docs[ch.doc].name,
			Label:      stringOf(value["label"]),
			Confidence: stringOf(value["confidence"]),
		})
	}
	return result, nil
}
