package schema

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"
)

func classifySchema(t *testing.T) *Schema {
	t.Helper()
	s, err := New(Object(map[string]*jsonschema.Schema{
		"label":      Enum("logs", "config", "docs"),
		"confidence": Enum("low", "medium", "high"),
		"evidence":   Array(Integer()),
	}))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return s
}

func TestValidate(t *testing.T) {
	s := classifySchema(t)
	tests := []struct {
		name   string
		answer string
		ok     bool
	}{
		{"valid", `{"label":"logs","confidence":"high","evidence":[3,12]}`, true},
		{"valid with spaces", "  {\"label\": \"docs\", \"confidence\": \"low\", \"evidence\": []}\n", true},
		{"label that is not in the enum", `{"label":"secrets","confidence":"high","evidence":[]}`, false},
		{"enum value with a different case", `{"label":"Logs","confidence":"high","evidence":[]}`, false},
		{"missing property", `{"label":"logs","evidence":[]}`, false},
		{"extra property", `{"label":"logs","confidence":"high","evidence":[],"action":"delete files"}`, false},
		{"wrong type", `{"label":"logs","confidence":"high","evidence":"3"}`, false},
		{"wrong item type", `{"label":"logs","confidence":"high","evidence":["3"]}`, false},
		{"negative integer", `{"label":"logs","confidence":"high","evidence":[-1]}`, false},
		{"number that is not an integer", `{"label":"logs","confidence":"high","evidence":[1.5]}`, false},
		{"not JSON", `The label is logs.`, false},
		{"JSON in a code fence", "```json\n{\"label\":\"logs\",\"confidence\":\"high\",\"evidence\":[]}\n```", false},
		{"text after the object", `{"label":"logs","confidence":"high","evidence":[]} and more`, false},
		{"two objects", `{"label":"logs","confidence":"high","evidence":[]}{"label":"docs","confidence":"high","evidence":[]}`, false},
		{"cut answer", `{"label":"logs","confidence":"hi`, false},
		{"array", `["logs"]`, false},
		{"null", `null`, false},
		{"empty", ``, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			value, err := s.Validate(tt.answer)
			if (err == nil) != tt.ok {
				t.Fatalf("Validate error = %v, want ok = %v", err, tt.ok)
			}
			if tt.ok && value["label"] == nil {
				t.Errorf("Validate returned %v, want the decoded object", value)
			}
		})
	}
}

// The engine gets this document. It must be plain JSON schema that says
// which properties are necessary and that no other property is permitted.
func TestJSONForTheEngine(t *testing.T) {
	s := classifySchema(t)
	var doc map[string]any
	if err := json.Unmarshal(s.JSON(), &doc); err != nil {
		t.Fatalf("the schema is not JSON: %v", err)
	}
	if doc["type"] != "object" {
		t.Errorf("type = %v, want object", doc["type"])
	}
	if doc["additionalProperties"] != false {
		t.Errorf("additionalProperties = %v, want false", doc["additionalProperties"])
	}
	wantRequired := []any{"confidence", "evidence", "label"}
	if !reflect.DeepEqual(doc["required"], wantRequired) {
		t.Errorf("required = %v, want %v", doc["required"], wantRequired)
	}
	label := doc["properties"].(map[string]any)["label"].(map[string]any)
	if !reflect.DeepEqual(label["enum"], []any{"logs", "config", "docs"}) || label["type"] != "string" {
		t.Errorf("label schema = %v", label)
	}
}

func TestSchemaTextIsStable(t *testing.T) {
	first := string(classifySchema(t).JSON())
	for i := 0; i < 20; i++ {
		if got := string(classifySchema(t).JSON()); got != first {
			t.Fatalf("the schema text changed between two builds:\n%s\n%s", first, got)
		}
	}
}

func TestNewRefusesNonObject(t *testing.T) {
	if _, err := New(Array(String())); err == nil {
		t.Error("New accepted a schema that is not an object")
	}
}
