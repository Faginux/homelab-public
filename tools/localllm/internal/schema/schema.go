// Package schema builds the JSON schema of a model answer and checks the
// answer against it (layer L5 of the plan).
//
// One schema object has two uses: the engine gets it as the "format" of the
// request, and this code checks the answer with it. Thus the two cannot
// disagree.
package schema

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"

	"github.com/google/jsonschema-go/jsonschema"
)

// Schema is a schema that is ready for the two uses.
type Schema struct {
	raw      json.RawMessage
	resolved *jsonschema.Resolved
}

// New prepares a schema. The top level must be an object.
func New(s *jsonschema.Schema) (*Schema, error) {
	if s.Type != "object" {
		return nil, errors.New("schema: the top level must be an object")
	}
	raw, err := json.Marshal(s)
	if err != nil {
		return nil, fmt.Errorf("schema: encode: %w", err)
	}
	resolved, err := s.Resolve(nil)
	if err != nil {
		return nil, fmt.Errorf("schema: resolve: %w", err)
	}
	return &Schema{raw: raw, resolved: resolved}, nil
}

// JSON returns the schema document for the engine.
func (s *Schema) JSON() json.RawMessage {
	return s.raw
}

// Validate decodes a model answer and checks it. The answer must be exactly
// one JSON object. The error text can quote the answer, so a caller must
// not put it in a result.
func (s *Schema) Validate(answer string) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader([]byte(answer)))
	var value map[string]any
	if err := dec.Decode(&value); err != nil {
		return nil, fmt.Errorf("schema: the answer is not a JSON object: %w", err)
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("schema: the answer has text after the JSON object")
	}
	if value == nil {
		return nil, errors.New("schema: the answer is null")
	}
	if err := s.resolved.Validate(value); err != nil {
		return nil, fmt.Errorf("schema: the answer does not agree with the schema: %w", err)
	}
	return value, nil
}

// Object returns an object schema. All properties are necessary and no
// other property is permitted.
func Object(properties map[string]*jsonschema.Schema) *jsonschema.Schema {
	required := make([]string, 0, len(properties))
	for name := range properties {
		required = append(required, name)
	}
	// A stable sequence gives the same schema text, and thus the same
	// grammar in the engine, for each call.
	sort.Strings(required)
	return &jsonschema.Schema{
		Type:                 "object",
		Properties:           properties,
		Required:             required,
		AdditionalProperties: &jsonschema.Schema{Not: &jsonschema.Schema{}},
	}
}

// String returns a string schema.
func String() *jsonschema.Schema {
	return &jsonschema.Schema{Type: "string"}
}

// Integer returns an integer schema with a minimum of 0.
func Integer() *jsonschema.Schema {
	return &jsonschema.Schema{Type: "integer", Minimum: jsonschema.Ptr(0.0)}
}

// Enum returns a string schema that permits only the given values.
func Enum(values ...string) *jsonschema.Schema {
	enum := make([]any, len(values))
	for i, v := range values {
		enum[i] = v
	}
	return &jsonschema.Schema{Type: "string", Enum: enum}
}

// Array returns an array schema.
func Array(items *jsonschema.Schema) *jsonschema.Schema {
	return &jsonschema.Schema{Type: "array", Items: items}
}
