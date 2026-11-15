package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"localllm/internal/gpu"
	"localllm/internal/tasks"
)

// These tests run the real command with the real path policy, the real
// HTTP client and the real audit log. Only the engine and the GPU query are
// synthetic. They are the acceptance tests of the plan in a small form.

const (
	testTag    = "small:1"
	testDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	goodAnswer = `{"summary":"The service lost the database.","key_points":["Database lost"],"confidence":"high"}`
)

type env struct {
	t       *testing.T
	base    string
	root    string
	outside string
	config  string
	audit   string
	staging string
	server  *httptest.Server
	chats   []string
	answers []string
}

func newEnv(t *testing.T, change func(doc map[string]any)) *env {
	t.Helper()
	base := t.TempDir()
	e := &env{
		t: t, base: base,
		root:    filepath.Join(base, "root"),
		outside: filepath.Join(base, "outside"),
		config:  filepath.Join(base, "config.json"),
		audit:   filepath.Join(base, "audit"),
		staging: filepath.Join(base, "staging"),
	}
	for _, dir := range []string{e.root, e.outside} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"version":"0.40.13"}`)
	})
	mux.HandleFunc("GET /api/tags", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"models":[{"name":%q,"digest":%q}]}`, testTag, testDigest)
	})
	mux.HandleFunc("GET /api/ps", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"models":[]}`)
	})
	mux.HandleFunc("POST /api/chat", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		e.chats = append(e.chats, string(body))
		answer := goodAnswer
		if len(e.answers) > 0 {
			answer, e.answers = e.answers[0], e.answers[1:]
		}
		reply, _ := json.Marshal(map[string]any{
			"message": map[string]string{"role": "assistant", "content": answer},
			"done":    true, "done_reason": "stop", "prompt_eval_count": 50, "eval_count": 10,
		})
		w.Write(reply)
	})
	e.server = httptest.NewServer(mux)
	t.Cleanup(e.server.Close)

	lock := filepath.Join(base, "models.lock.json")
	e.write(lock, fmt.Sprintf(`{"models":[{"tag":%q,"digest":%q,"vram_mib":3000}]}`, testTag, testDigest))
	doc := map[string]any{
		"ollama_url":      e.server.URL,
		"allowed_roots":   []string{e.root},
		"staging_dir":     e.staging,
		"audit_dir":       e.audit,
		"models_lock":     lock,
		"vram_budget_mib": 7926,
		"models":          map[string]any{"default": map[string]string{"s": testTag}},
	}
	if change != nil {
		change(doc)
	}
	raw, _ := json.Marshal(doc)
	e.write(e.config, string(raw))

	previous := queryGPU
	queryGPU = func(context.Context) (gpu.Status, error) {
		return gpu.Status{TotalMiB: 12288, UsedMiB: 1000, FreeMiB: 11288}, nil
	}
	t.Cleanup(func() { queryGPU = previous })
	return e
}

func (e *env) write(path, content string) string {
	e.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		e.t.Fatal(err)
	}
	return path
}

// cli runs the command and returns the exit code and the two outputs.
func (e *env) cli(stdin string, args ...string) (int, string, string) {
	e.t.Helper()
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), append(args, "--config", e.config), strings.NewReader(stdin), &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func (e *env) envelope(stdout string) tasks.Envelope {
	e.t.Helper()
	var result tasks.Envelope
	if err := json.Unmarshal([]byte(stdout), &result); err != nil {
		e.t.Fatalf("stdout is not a JSON result: %v\n%s", err, stdout)
	}
	if result.Label != tasks.OutputLabel {
		e.t.Errorf("label = %q, want %q", result.Label, tasks.OutputLabel)
	}
	return result
}

func (e *env) auditText() string {
	e.t.Helper()
	var all strings.Builder
	items, _ := os.ReadDir(e.audit)
	for _, item := range items {
		raw, err := os.ReadFile(filepath.Join(e.audit, item.Name()))
		if err != nil {
			e.t.Fatal(err)
		}
		all.Write(raw)
	}
	return all.String()
}

func rep(s string, n int) string { return strings.Repeat(s, n) }

func TestCanarySecretsStayLocal(t *testing.T) {
	canaries := []string{
		"CANARY" + rep("a", 14),
		"gh" + "p_" + rep("B", 36),
		"1234567" + "890:" + rep("C", 35),
	}
	e := newEnv(t, nil)
	path := e.write(filepath.Join(e.root, "app.log"), strings.Join([]string{
		"10:00 start",
		"DB_PASSWORD=" + canaries[0],
		"git clone https://x:" + canaries[1] + "@example.invalid/repo",
		"POST /bot" + canaries[2] + "/sendMessage 200",
		"10:05 ERROR database connection lost",
	}, "\n"))

	code, stdout, stderr := e.cli("", "run", "summarize", "--path", path)
	if code != exitOK {
		t.Fatalf("exit code = %d\nstdout: %s\nstderr: %s", code, stdout, stderr)
	}
	result := e.envelope(stdout)
	if result.Status != tasks.StatusOK || result.Model != testTag || result.Stats.Redactions < 3 {
		t.Errorf("result = %+v, stats = %+v", result, result.Stats)
	}
	if len(e.chats) != 1 {
		t.Fatalf("the engine got %d chat requests, want 1", len(e.chats))
	}
	audit := e.auditText()
	for _, canary := range canaries {
		for name, text := range map[string]string{"the engine request": e.chats[0], "stdout": stdout, "the audit log": audit} {
			if strings.Contains(text, canary) {
				t.Errorf("a canary is in %s", name)
			}
		}
	}
	if !strings.Contains(e.chats[0], "database connection lost") {
		t.Error("the ordinary text did not go to the engine")
	}
	if strings.Contains(e.chats[0], `"tools"`) {
		t.Error("the engine request has a tools field")
	}
	if !strings.Contains(audit, `"status":"ok"`) || !strings.Contains(audit, `"sha256":"`) || strings.Contains(audit, "connection lost") {
		t.Errorf("audit log = %s", audit)
	}
}

func TestRefusedPaths(t *testing.T) {
	e := newEnv(t, nil)
	e.write(filepath.Join(e.outside, "plain.txt"), "outside content\n")
	junction := filepath.Join(e.root, "to-outside")
	if out, err := exec.Command("cmd", "/c", "mklink", "/J", junction, e.outside).CombinedOutput(); err != nil {
		t.Fatalf("mklink /J: %v: %s", err, out)
	}
	t.Cleanup(func() { os.Remove(junction) })

	tests := []struct {
		name       string
		path       string
		wantReason string
	}{
		{"secret file in the root", e.write(filepath.Join(e.root, "stack", ".env"), "DB_PASSWORD=synthetic\n"), "denied_name"},
		{"private key in the root", e.write(filepath.Join(e.root, "server.key"), "synthetic\n"), "denied_name"},
		{"path outside the roots", filepath.Join(e.outside, "plain.txt"), "outside_roots"},
		{"junction to a folder outside the roots", filepath.Join(junction, "plain.txt"), "outside_roots"},
		{"missing file", filepath.Join(e.root, "missing.txt"), "not_found"},
		{"binary file", e.write(filepath.Join(e.root, "data.bin"), "a\x00b"), "binary"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, stdout, _ := e.cli("", "run", "summarize", "--path", tt.path)
			result := e.envelope(stdout)
			if code != exitFailed || result.Status != tasks.StatusRefused || result.Reason != tt.wantReason {
				t.Errorf("exit code = %d, status = %q, reason = %q, want 1, refused, %q", code, result.Status, result.Reason, tt.wantReason)
			}
		})
	}
	if len(e.chats) != 0 {
		t.Errorf("the engine got %d chat requests for refused paths", len(e.chats))
	}
	if n := strings.Count(e.auditText(), `"status":"refused"`); n != len(tests) {
		t.Errorf("audit records of refusals = %d, want %d", n, len(tests))
	}
}

func TestFallbackStatuses(t *testing.T) {
	t.Run("low VRAM budget gives busy", func(t *testing.T) {
		e := newEnv(t, func(doc map[string]any) { doc["vram_budget_mib"] = 100 })
		code, stdout, _ := e.cli("some text", "run", "summarize", "--stdin")
		if result := e.envelope(stdout); code != exitFailed || result.Status != tasks.StatusBusy {
			t.Errorf("exit code = %d, status = %q, want 1 and busy", code, result.Status)
		}
		if len(e.chats) != 0 {
			t.Error("the engine got a chat request")
		}
	})
	t.Run("low free VRAM gives busy", func(t *testing.T) {
		e := newEnv(t, nil)
		queryGPU = func(context.Context) (gpu.Status, error) { return gpu.Status{FreeMiB: 2000}, nil }
		code, stdout, _ := e.cli("some text", "run", "summarize", "--stdin")
		if result := e.envelope(stdout); code != exitFailed || result.Status != tasks.StatusBusy || result.Reason != "vram" {
			t.Errorf("exit code = %d, status = %q, reason = %q", code, result.Status, result.Reason)
		}
	})
	t.Run("stopped engine gives engine_down", func(t *testing.T) {
		e := newEnv(t, nil)
		e.server.Close()
		code, stdout, _ := e.cli("some text", "run", "summarize", "--stdin")
		if result := e.envelope(stdout); code != exitFailed || result.Status != tasks.StatusEngineDown {
			t.Errorf("exit code = %d, status = %q, want 1 and engine_down", code, result.Status)
		}
	})
	t.Run("bad answers give one retry, then schema_invalid", func(t *testing.T) {
		e := newEnv(t, nil)
		e.answers = []string{"I cannot answer in JSON.", `{"summary":"x"}`}
		code, stdout, _ := e.cli("some text", "run", "summarize", "--stdin")
		if result := e.envelope(stdout); code != exitFailed || result.Status != tasks.StatusSchemaInvalid {
			t.Errorf("exit code = %d, status = %q, want 1 and schema_invalid", code, result.Status)
		}
		if len(e.chats) != 2 {
			t.Errorf("chat requests = %d, want 2", len(e.chats))
		}
	})
	t.Run("model with a changed digest is refused", func(t *testing.T) {
		e := newEnv(t, nil)
		lock := filepath.Join(e.base, "models.lock.json")
		e.write(lock, fmt.Sprintf(`{"models":[{"tag":%q,"digest":%q,"vram_mib":3000}]}`, testTag, rep("f", 64)))
		code, stdout, _ := e.cli("some text", "run", "summarize", "--stdin")
		if result := e.envelope(stdout); code != exitFailed || result.Status != tasks.StatusModelNotAllowed || result.Reason != "digest_mismatch" {
			t.Errorf("exit code = %d, status = %q, reason = %q", code, result.Status, result.Reason)
		}
	})
}

func TestRunVariants(t *testing.T) {
	t.Run("pipe on stdin", func(t *testing.T) {
		e := newEnv(t, nil)
		code, stdout, _ := e.cli("10:05 ERROR database connection lost\n", "run", "summarize", "--stdin", "--style", "text", "--focus", "the database")
		if result := e.envelope(stdout); code != exitOK || result.Status != tasks.StatusOK {
			t.Fatalf("exit code = %d, status = %q", code, result.Status)
		}
		if !strings.Contains(e.chats[0], "Focus of the summary: the database") {
			t.Error("the focus is not in the request")
		}
	})
	t.Run("relative path", func(t *testing.T) {
		e := newEnv(t, nil)
		e.write(filepath.Join(e.root, "notes.md"), "some notes\n")
		t.Chdir(e.root)
		code, stdout, _ := e.cli("", "run", "summarize", "--path", "notes.md")
		if result := e.envelope(stdout); code != exitOK || result.Status != tasks.StatusOK {
			t.Errorf("exit code = %d, status = %q, reason = %q", code, result.Status, result.Reason)
		}
	})
	t.Run("classify with labels", func(t *testing.T) {
		e := newEnv(t, nil)
		e.answers = []string{`{"label":"logs","confidence":"high"}`}
		path := e.write(filepath.Join(e.root, "a.txt"), "10:00 INFO started\n")
		code, stdout, _ := e.cli("", "run", "classify", "--path", path, "--label", "logs", "--label", "docs")
		if code != exitOK || !strings.Contains(stdout, `"label": "logs"`) {
			t.Errorf("exit code = %d\n%s", code, stdout)
		}
	})
	t.Run("extract with fields", func(t *testing.T) {
		e := newEnv(t, nil)
		e.answers = []string{`{"version":"3.4.1","changes":["one"]}`}
		code, stdout, _ := e.cli("version 3.4.1", "run", "extract", "--stdin", "--field", "version:string:the version number", "--field", "changes:list")
		if code != exitOK || !strings.Contains(stdout, `"version": "3.4.1"`) {
			t.Errorf("exit code = %d\n%s", code, stdout)
		}
	})
	t.Run("draft goes to the staging folder", func(t *testing.T) {
		e := newEnv(t, nil)
		e.answers = []string{"# Title\n\nDraft text."}
		code, stdout, _ := e.cli("", "run", "draft", "--kind", "markdown", "--instruction", "Write a short note.")
		result := e.envelope(stdout)
		if code != exitOK || result.Status != tasks.StatusOK {
			t.Fatalf("exit code = %d, status = %q", code, result.Status)
		}
		var files []string
		filepath.WalkDir(e.base, func(path string, d os.DirEntry, err error) error {
			if err == nil && !d.IsDir() && strings.HasSuffix(path, ".md") {
				files = append(files, path)
			}
			return nil
		})
		if len(files) != 1 || !strings.HasPrefix(files[0], e.staging+string(filepath.Separator)) {
			t.Errorf("draft files = %v, want one file in %s", files, e.staging)
		}
	})
}

func TestHealthStatsAndEval(t *testing.T) {
	e := newEnv(t, nil)

	code, stdout, _ := e.cli("", "health")
	if code != exitOK || !strings.Contains(stdout, `"engine": "up"`) || !strings.Contains(stdout, `"allowed_roots"`) || !strings.Contains(stdout, `"state": "ready"`) {
		t.Errorf("health: exit code = %d\n%s", code, stdout)
	}

	for i := 0; i < 2; i++ {
		e.cli(rep("log line\n", 500), "run", "summarize", "--stdin")
	}
	e.cli("", "run", "summarize", "--path", filepath.Join(e.outside, "x.txt"))
	code, stdout, _ = e.cli("", "stats", "--days", "1")
	var stats struct {
		Calls    int            `json:"calls"`
		ByStatus map[string]int `json:"by_status"`
		NotRead  int64          `json:"estimated_tokens_not_read"`
	}
	if err := json.Unmarshal([]byte(stdout), &stats); err != nil || code != exitOK {
		t.Fatalf("stats: exit code = %d, %v\n%s", code, err, stdout)
	}
	if stats.Calls != 3 || stats.ByStatus["ok"] != 2 || stats.ByStatus["refused"] != 1 || stats.NotRead < 1000 {
		t.Errorf("stats = %+v", stats)
	}

	cases := filepath.Join(e.root, "eval")
	e.write(filepath.Join(cases, "one.log"), "10:05 ERROR database connection lost\n")
	e.write(filepath.Join(cases, "one.json"), `{"task":"summarize","input":"one.log","expect":{"facts":["database"]}}`)
	code, stdout, _ = e.cli("", "eval", "--cases", cases)
	if code != exitOK || !strings.Contains(stdout, `"pass": true`) || !strings.Contains(stdout, `"fact_recall": 1`) {
		t.Errorf("eval: exit code = %d\n%s", code, stdout)
	}
}

func TestCommandLineErrors(t *testing.T) {
	e := newEnv(t, nil)
	tests := []struct {
		name string
		args []string
		want int
	}{
		{"unknown command", []string{"shell"}, exitUsage},
		{"run with no task", []string{"run"}, exitUsage},
		{"run with a flag as the task", []string{"run", "--stdin"}, exitUsage},
		{"unknown flag", []string{"run", "summarize", "--exec", "whoami"}, exitUsage},
		{"extra argument", []string{"run", "summarize", "--stdin", "extra"}, exitUsage},
		{"field with no type", []string{"run", "extract", "--stdin", "--field", "version"}, exitUsage},
		{"stats with too many days", []string{"stats", "--days", "400"}, exitUsage},
		{"eval with no folder", []string{"eval"}, exitUsage},
		{"unknown task", []string{"run", "shell", "--stdin"}, exitFailed},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, _, _ := e.cli("text", tt.args...)
			if code != tt.want {
				t.Errorf("exit code = %d, want %d", code, tt.want)
			}
		})
	}

	t.Run("no arguments", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		if code := run(context.Background(), nil, strings.NewReader(""), &stdout, &stderr); code != exitUsage || !strings.Contains(stderr.String(), "Usage:") {
			t.Errorf("exit code = %d, stderr = %q", code, stderr.String())
		}
	})
	t.Run("missing config", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		code := run(context.Background(), []string{"health", "--config", filepath.Join(e.base, "none.json")}, strings.NewReader(""), &stdout, &stderr)
		if code != exitFailed || stdout.Len() != 0 {
			t.Errorf("exit code = %d, stdout = %q", code, stdout.String())
		}
	})
	t.Run("config with a remote engine", func(t *testing.T) {
		remote := newEnv(t, func(doc map[string]any) { doc["ollama_url"] = "http://192.0.2.10:11434" })
		code, stdout, stderr := remote.cli("text", "run", "summarize", "--stdin")
		if code != exitFailed || stdout != "" || !strings.Contains(stderr, "loopback") {
			t.Errorf("exit code = %d, stdout = %q, stderr = %q", code, stdout, stderr)
		}
	})
	t.Run("version", func(t *testing.T) {
		var stdout, stderr bytes.Buffer
		if code := run(context.Background(), []string{"version"}, strings.NewReader(""), &stdout, &stderr); code != exitOK || strings.TrimSpace(stdout.String()) != version {
			t.Errorf("exit code = %d, stdout = %q", code, stdout.String())
		}
	})
}
