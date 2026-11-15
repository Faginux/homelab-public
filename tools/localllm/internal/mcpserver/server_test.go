package mcpserver

import (
	"context"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"localllm/internal/config"
	"localllm/internal/tasks"
)

// fakeTasks records the requests and gives a fixed result.
type fakeTasks struct {
	requests    []tasks.Request
	healthCalls int
	status      string
}

func (f *fakeTasks) Run(_ context.Context, req tasks.Request) tasks.Envelope {
	f.requests = append(f.requests, req)
	return tasks.Envelope{Label: tasks.OutputLabel, Status: f.status, Task: req.Task, Result: map[string]string{"summary": "synthetic"}}
}

func (f *fakeTasks) Health(context.Context) tasks.Envelope {
	f.healthCalls++
	return tasks.Envelope{Label: tasks.OutputLabel, Status: tasks.StatusOK, Task: tasks.TaskHealth}
}

// connect starts the server and a client on a transport in memory.
func connect(t *testing.T, runner Tasks) *mcp.ClientSession {
	t.Helper()
	serverSide, clientSide := mcp.NewInMemoryTransports()
	server := New(runner, "test")
	serverSession, err := server.Connect(t.Context(), serverSide, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { serverSession.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "test"}, nil)
	session, err := client.Connect(t.Context(), clientSide, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { session.Close() })
	return session
}

func call(t *testing.T, session *mcp.ClientSession, tool string, args map[string]any) (*mcp.CallToolResult, error) {
	t.Helper()
	return session.CallTool(t.Context(), &mcp.CallToolParams{Name: tool, Arguments: args})
}

func envelopeOf(t *testing.T, result *mcp.CallToolResult) tasks.Envelope {
	t.Helper()
	if len(result.Content) != 1 {
		t.Fatalf("content items = %d, want 1", len(result.Content))
	}
	text, ok := result.Content[0].(*mcp.TextContent)
	if !ok {
		t.Fatalf("content = %T, want text", result.Content[0])
	}
	var env tasks.Envelope
	if err := json.Unmarshal([]byte(text.Text), &env); err != nil {
		t.Fatalf("the tool result is not JSON: %v\n%s", err, text.Text)
	}
	return env
}

func TestServerHasExactlyFiveTools(t *testing.T) {
	session := connect(t, &fakeTasks{status: tasks.StatusOK})
	list, err := session.ListTools(t.Context(), nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	var names []string
	for _, tool := range list.Tools {
		names = append(names, tool.Name)
		if tool.Description == "" {
			t.Errorf("tool %s has no description", tool.Name)
		}
		if tool.Name == ToolHealth {
			continue
		}
		if !strings.Contains(tool.Description, tasks.OutputLabel) {
			t.Errorf("the description of %s does not tell that the output is untrusted data", tool.Name)
		}
	}
	sort.Strings(names)
	want := []string{ToolClassify, ToolDraft, ToolExtract, ToolHealth, ToolSummarize}
	if !reflect.DeepEqual(names, want) {
		t.Errorf("tools = %v, want %v", names, want)
	}
}

func TestToolCallsBecomeRequests(t *testing.T) {
	tests := []struct {
		name string
		tool string
		args map[string]any
		want tasks.Request
	}{
		{"summarize with paths", ToolSummarize,
			map[string]any{"paths": []string{`C:\data\app.log`}, "style": "log", "focus": "database errors", "tier": "m"},
			tasks.Request{Task: config.TaskSummarize, Paths: []string{`C:\data\app.log`}, Inline: true, Style: "log", Focus: "database errors", Tier: "m"}},
		{"summarize with inline text", ToolSummarize,
			map[string]any{"text": "short text"},
			tasks.Request{Task: config.TaskSummarize, Text: "short text", Inline: true}},
		{"extract", ToolExtract,
			map[string]any{"paths": []string{`C:\data\notes.md`}, "fields": []map[string]any{{"name": "version", "type": "string", "description": "the version"}, {"name": "changes", "type": "list"}}},
			tasks.Request{Task: config.TaskExtract, Paths: []string{`C:\data\notes.md`}, Inline: true,
				Fields: []tasks.Field{{Name: "version", Type: "string", Description: "the version"}, {Name: "changes", Type: "list"}}}},
		{"classify", ToolClassify,
			map[string]any{"paths": []string{`C:\data\a.txt`, `C:\data\b.txt`}, "labels": []string{"logs", "docs"}},
			tasks.Request{Task: config.TaskClassify, Paths: []string{`C:\data\a.txt`, `C:\data\b.txt`}, Inline: true, Labels: []string{"logs", "docs"}}},
		{"draft", ToolDraft,
			map[string]any{"instruction": "Write a function.", "kind": "powershell"},
			tasks.Request{Task: config.TaskDraft, Instruction: "Write a function.", Kind: "powershell"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			runner := &fakeTasks{status: tasks.StatusOK}
			result, err := call(t, connect(t, runner), tt.tool, tt.args)
			if err != nil {
				t.Fatalf("CallTool: %v", err)
			}
			if len(runner.requests) != 1 || !reflect.DeepEqual(runner.requests[0], tt.want) {
				t.Fatalf("request = %+v\nwant      %+v", runner.requests, tt.want)
			}
			env := envelopeOf(t, result)
			if env.Label != tasks.OutputLabel || env.Status != tasks.StatusOK {
				t.Errorf("envelope = %+v", env)
			}
		})
	}
}

func TestHealthTool(t *testing.T) {
	runner := &fakeTasks{}
	result, err := call(t, connect(t, runner), ToolHealth, map[string]any{})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if env := envelopeOf(t, result); env.Task != tasks.TaskHealth || runner.healthCalls != 1 {
		t.Errorf("envelope = %+v, health calls = %d", env, runner.healthCalls)
	}
}

// A status that is not "ok" is a normal result, so that the orchestrator
// reads the status and uses its fallback.
func TestFailureStatusIsNotAToolError(t *testing.T) {
	for _, status := range []string{tasks.StatusBusy, tasks.StatusEngineDown, tasks.StatusRefused, tasks.StatusSchemaInvalid} {
		t.Run(status, func(t *testing.T) {
			result, err := call(t, connect(t, &fakeTasks{status: status}), ToolSummarize, map[string]any{"text": "x"})
			if err != nil {
				t.Fatalf("CallTool: %v", err)
			}
			if result.IsError {
				t.Error("the result is a tool error")
			}
			if env := envelopeOf(t, result); env.Status != status {
				t.Errorf("status = %q, want %q", env.Status, status)
			}
		})
	}
}

func TestBadArgumentsDoNotReachTheRunner(t *testing.T) {
	tests := []struct {
		name string
		tool string
		args map[string]any
	}{
		{"paths is not a list", ToolSummarize, map[string]any{"paths": `C:\data\app.log`}},
		{"unknown argument", ToolSummarize, map[string]any{"text": "x", "shell": "whoami"}},
		{"extract with no fields", ToolExtract, map[string]any{"text": "x"}},
		{"classify with no labels", ToolClassify, map[string]any{"text": "x"}},
		{"draft with no kind", ToolDraft, map[string]any{"instruction": "write"}},
		{"draft with text", ToolDraft, map[string]any{"instruction": "write", "kind": "text", "text": "x"}},
		{"unknown tool", "llm_shell", map[string]any{"command": "whoami"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			runner := &fakeTasks{status: tasks.StatusOK}
			result, err := call(t, connect(t, runner), tt.tool, tt.args)
			if err == nil && !result.IsError {
				t.Error("the call gave a result, want a refusal")
			}
			if len(runner.requests) != 0 {
				t.Errorf("the runner got a request: %+v", runner.requests)
			}
		})
	}
}
