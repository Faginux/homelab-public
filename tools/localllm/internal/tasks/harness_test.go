package tasks

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"localllm/internal/audit"
	"localllm/internal/config"
	"localllm/internal/gpu"
	"localllm/internal/ollama"
	"localllm/internal/policy"
)

const (
	smallTag  = "small:1"
	mediumTag = "medium:1"
)

var (
	smallDigest  = strings.Repeat("a1", 32)
	mediumDigest = strings.Repeat("b2", 32)
)

// fakeEngine is a synthetic engine. A test gives the answers of the model
// in sequence and reads the requests afterward.
type fakeEngine struct {
	t        *testing.T
	models   []ollama.Model
	loaded   []ollama.LoadedModel
	answers  []string
	chatErr  error
	readErr  error
	requests []ollama.ChatRequest
}

func (e *fakeEngine) Version(context.Context) (string, error) { return "0.40.13", e.readErr }

func (e *fakeEngine) Models(context.Context) ([]ollama.Model, error) { return e.models, e.readErr }

func (e *fakeEngine) Loaded(context.Context) ([]ollama.LoadedModel, error) {
	return e.loaded, e.readErr
}

func (e *fakeEngine) VerifyDigest(_ context.Context, tag, digest string) error {
	if e.readErr != nil {
		return e.readErr
	}
	for _, m := range e.models {
		if m.Name == tag {
			if m.Digest != digest {
				return ollama.ErrDigestMismatch
			}
			return nil
		}
	}
	return ollama.ErrModelNotInstalled
}

func (e *fakeEngine) Chat(_ context.Context, req ollama.ChatRequest) (ollama.ChatResponse, error) {
	e.requests = append(e.requests, req)
	if e.chatErr != nil {
		return ollama.ChatResponse{}, e.chatErr
	}
	if len(e.answers) == 0 {
		e.t.Errorf("the engine got request %d, but the test has no answer for it", len(e.requests))
		return ollama.ChatResponse{Content: "{}"}, nil
	}
	answer := e.answers[0]
	e.answers = e.answers[1:]
	return ollama.ChatResponse{Content: answer, PromptTokens: 100, OutputTokens: 20, DoneReason: "stop"}, nil
}

// prompts returns the text of all requests: what the model got.
func (e *fakeEngine) prompts() string {
	var b strings.Builder
	for _, req := range e.requests {
		b.WriteString(req.System + "\n" + req.User + "\n" + string(req.Schema) + "\n")
	}
	return b.String()
}

// fakeFiles gives synthetic files with no disk access. A path that is not
// in the map gets the refusal in err, or "not_found".
type fakeFiles struct {
	files map[string]string
	err   error
	calls int
}

func (f *fakeFiles) ReadAll(paths []string) ([]*policy.File, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	var out []*policy.File
	for _, path := range paths {
		text, ok := f.files[path]
		if !ok {
			return nil, &policy.Error{Code: policy.CodeNotFound, Path: path, Detail: "the file does not exist"}
		}
		out = append(out, &policy.File{
			Requested: path, Canonical: path, Name: filepath.Base(strings.ReplaceAll(path, `\`, "/")),
			Text: text, Bytes: int64(len(text)), SHA256: strings.Repeat("f", 64),
		})
	}
	return out, nil
}

type memAudit struct {
	entries []audit.Entry
	err     error
}

func (a *memAudit) Write(entry audit.Entry) error {
	if a.err != nil {
		return a.err
	}
	a.entries = append(a.entries, entry)
	return nil
}

// harness is a Runner with synthetic parts.
type harness struct {
	t        *testing.T
	runner   *Runner
	engine   *fakeEngine
	files    *fakeFiles
	audit    *memAudit
	gpuFree  int
	gpuErr   error
	gpuCalls int
	staging  string
}

func newHarness(t *testing.T, change func(doc map[string]any)) *harness {
	t.Helper()
	dir := t.TempDir()
	doc := map[string]any{
		"ollama_url":      "http://127.0.0.1:11434",
		"allowed_roots":   []string{filepath.Join(dir, "root")},
		"staging_dir":     filepath.Join(dir, "staging"),
		"audit_dir":       filepath.Join(dir, "logs"),
		"models_lock":     filepath.Join(dir, "models.lock.json"),
		"vram_budget_mib": 7926,
		"chunk_chars":     1000,
		"models":          map[string]any{"default": map[string]string{"s": smallTag, "m": mediumTag}},
	}
	if change != nil {
		change(doc)
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Parse(raw)
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	lock, err := config.ParseLock([]byte(fmt.Sprintf(
		`{"models":[{"tag":%q,"digest":%q,"vram_mib":3000},{"tag":%q,"digest":%q,"vram_mib":6000}]}`,
		smallTag, smallDigest, mediumTag, mediumDigest)))
	if err != nil {
		t.Fatalf("lock: %v", err)
	}

	h := &harness{
		t: t,
		engine: &fakeEngine{t: t, models: []ollama.Model{
			{Name: smallTag, Digest: smallDigest},
			{Name: mediumTag, Digest: mediumDigest},
		}},
		files:   &fakeFiles{files: map[string]string{}},
		audit:   &memAudit{},
		gpuFree: 11000,
		staging: cfg.StagingDir,
	}
	h.runner = &Runner{
		Config: cfg, Lock: lock, Files: h.files, Engine: h.engine, Audit: h.audit, Mode: "test",
		QueryGPU: func(context.Context) (gpu.Status, error) {
			h.gpuCalls++
			return gpu.Status{TotalMiB: 12288, UsedMiB: 12288 - h.gpuFree, FreeMiB: h.gpuFree}, h.gpuErr
		},
		Now: func() time.Time { return time.Date(2026, 11, 15, 14, 30, 5, 0, time.UTC) },
	}
	return h
}

func (h *harness) run(req Request) Envelope {
	h.t.Helper()
	return h.runner.Run(context.Background(), req)
}

// resultJSON returns the result as JSON text, for comparisons.
func resultJSON(t *testing.T, env Envelope) string {
	t.Helper()
	raw, err := json.Marshal(env.Result)
	if err != nil {
		t.Fatalf("marshal the result: %v", err)
	}
	return string(raw)
}

func wantStatus(t *testing.T, env Envelope, status, reason string) {
	t.Helper()
	if env.Status != status || (reason != "" && env.Reason != reason) {
		t.Fatalf("status = %q, reason = %q (%s), want %q and %q", env.Status, env.Reason, env.Detail, status, reason)
	}
	if env.Label != OutputLabel {
		t.Errorf("label = %q, want %q", env.Label, OutputLabel)
	}
	if status != StatusOK && env.Result != nil {
		t.Errorf("a call with the status %q returned a result", status)
	}
}

const summaryAnswer = `{"summary":"The service started and then lost the database.","key_points":["Start at 10:00","Database lost at 10:05"],"confidence":"high"}`
