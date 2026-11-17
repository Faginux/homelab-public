package tasks

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"localllm/internal/config"
	"localllm/internal/ollama"
	"localllm/internal/policy"
	"localllm/internal/redact"
)

// These tests check the secret boundary: with raw input the model can see
// the secret values, but no result, draft, error text or audit record may
// contain them. The canary values are built at run time.

func rawInput(doc map[string]any) { doc["raw_model_input"] = true }

func spacedOut(s string) string { return strings.Join(strings.Split(s, ""), " ") }

func reversed(s string) string {
	r := []rune(s)
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	return string(r)
}

// wantNoCanary fails when a canary is in the text, also in a changed form.
func wantNoCanary(t *testing.T, where, text string, canaries ...string) {
	t.Helper()
	check := redact.NewTaint()
	check.Add(canaries...)
	for _, canary := range canaries {
		if strings.Contains(text, canary) {
			t.Errorf("%s: a canary is in the text", where)
		}
	}
	if _, n := check.Scrub(text); n > 0 {
		t.Errorf("%s: a canary is in the text in a changed form (%d hits)", where, n)
	}
}

func TestRawInputReachesTheModelButNotTheResult(t *testing.T) {
	envValue := "CANARY" + rep("e", 12)
	jsonValue := "CANARY" + rep("j", 12)
	bearerValue := "CANARY" + rep("b", 24)
	ghToken := "gh" + "p_" + rep("C", 36)
	input := strings.Join([]string{
		"POSTGRES_PASSWORD=" + envValue,
		`{"level":"info","api_key":"` + jsonValue + `","msg":"started"}`,
		"Authorization: Bearer " + bearerValue,
		"clone with " + ghToken,
		"10:05 database connection lost",
	}, "\n")
	answer := fmt.Sprintf(`{"summary":"The password is %s and the key is %s.","key_points":["token %s","reversed %s"],"confidence":"high"}`,
		envValue, spacedOut(jsonValue), base64.StdEncoding.EncodeToString([]byte(bearerValue)), reversed(ghToken))

	h := newHarness(t, rawInput)
	h.files.files[`C:\data\app.log`] = input
	h.engine.answers = []string{answer}
	env := h.run(Request{Task: config.TaskSummarize, Paths: []string{`C:\data\app.log`}})
	wantStatus(t, env, StatusOK, "")

	for _, canary := range []string{envValue, jsonValue, bearerValue, ghToken} {
		if !strings.Contains(h.engine.prompts(), canary) {
			t.Errorf("raw input: the model did not get the value %.10s…", canary)
		}
	}
	envelope, _ := json.Marshal(env)
	auditText, _ := json.Marshal(h.audit.entries)
	wantNoCanary(t, "result", string(envelope), envValue, jsonValue, bearerValue, ghToken)
	wantNoCanary(t, "audit", string(auditText), envValue, jsonValue, bearerValue, ghToken)

	entry := h.audit.entries[0]
	if !entry.RawModelInput {
		t.Error("the audit record does not say that the model got raw input")
	}
	if entry.RedactionsOut[redact.ClassTainted] < 3 {
		t.Errorf("tainted replacements = %v, want 3 or more", entry.RedactionsOut)
	}
	if !contains(env.Warnings, taintNotice) {
		t.Errorf("warnings = %q, want the taint notice", env.Warnings)
	}
}

func TestRedactedInputIsTheDefault(t *testing.T) {
	value := "CANARY" + rep("d", 14)
	h := newHarness(t, nil)
	h.engine.answers = []string{summaryAnswer}
	env := h.run(Request{Task: config.TaskSummarize, Text: "DB_PASSWORD=" + value + "\nstarted"})
	wantStatus(t, env, StatusOK, "")
	if strings.Contains(h.engine.prompts(), value) {
		t.Error("with the default config the model got a secret value")
	}
	if h.audit.entries[0].RawModelInput {
		t.Error("the audit record says raw input, but the config does not permit it")
	}
}

func TestLogEvidenceLinesGoThroughTheBoundary(t *testing.T) {
	value := "CANARY" + rep("L", 18)
	// The rules find the value in line 1. Line 2 has the value with no
	// name, so only the taint check can remove it from the evidence.
	text := "10:00 API_TOKEN=" + value + "\n10:01 ERROR retry with " + value + " failed\n10:02 INFO ok\n"
	h := newHarness(t, rawInput)
	h.engine.answers = []string{`{"top_errors":[{"message":"retry failed","count":1,"line":2}],"patterns":[],"notable_lines":[2]}`}
	env := h.run(Request{Task: config.TaskSummarize, Style: StyleLog, Text: text})
	wantStatus(t, env, StatusOK, "")

	got := resultJSON(t, env)
	wantNoCanary(t, "log digest", got, value)
	if !strings.Contains(got, "retry with "+redact.TaintMarker) {
		t.Errorf("the evidence line lost its ordinary text: %s", got)
	}
}

func TestDraftGoesThroughTheBoundary(t *testing.T) {
	value := "CANARY" + rep("r", 16)
	h := newHarness(t, rawInput)
	h.files.files[`C:\data\app.env.example`] = "DB_PASSWORD=" + value + "\n"
	h.engine.answers = []string{"Use the value " + value + " in the config."}
	env := h.run(Request{Task: config.TaskDraft, Kind: "text", Instruction: "Write a note.", Paths: []string{`C:\data\app.env.example`}})
	wantStatus(t, env, StatusOK, "")

	var draft Draft
	if err := json.Unmarshal([]byte(resultJSON(t, env)), &draft); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(draft.StagingFile)
	if err != nil {
		t.Fatalf("read the draft: %v", err)
	}
	wantNoCanary(t, "staging file", string(content), value)
	if !strings.Contains(string(content), "Use the value "+redact.TaintMarker) {
		t.Errorf("draft = %q", content)
	}
}

func TestEngineMessageGoesThroughTheBoundary(t *testing.T) {
	value := "CANARY" + rep("m", 16)
	h := newHarness(t, rawInput)
	h.engine.chatErr = &ollama.StatusError{Code: 400, Message: "invalid prompt near " + value}
	env := h.run(Request{Task: config.TaskSummarize, Text: "SECRET_KEY=" + value})
	wantStatus(t, env, StatusError, "engine_http_error")
	wantNoCanary(t, "error detail", env.Detail, value)
	if !strings.Contains(env.Detail, redact.TaintMarker) {
		t.Errorf("detail = %q", env.Detail)
	}
}

func TestTaintOverflowGivesRedactedInput(t *testing.T) {
	var lines []string
	for i := 0; i <= 2000; i++ {
		lines = append(lines, fmt.Sprintf("token_%04d=Val%08dxyz", i, i))
	}
	h := newHarness(t, rawInput)
	h.engine.answers = []string{summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer,
		summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer,
		summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer, summaryAnswer}
	h.runner.Config.ChunkChars = 8000
	env := h.run(Request{Task: config.TaskSummarize, Text: strings.Join(lines, "\n")})

	if strings.Contains(h.engine.prompts(), "Val00000001xyz") {
		t.Error("the taint set is not complete, but the model got raw input")
	}
	if !contains(env.Warnings, taintOverflowNotice) {
		t.Errorf("warnings = %q, want the overflow notice", env.Warnings)
	}
	if len(h.audit.entries) == 1 && h.audit.entries[0].RawModelInput {
		t.Error("the audit record says raw input after an overflow")
	}
}

func TestView(t *testing.T) {
	value := "CANARY" + rep("v", 14)
	var lines []string
	for i := 1; i <= 30; i++ {
		lines = append(lines, fmt.Sprintf("10:%02d INFO request %d", i, i))
	}
	lines[4] = "10:05 X-Api-Key: " + value
	// The live test of 2026-11-17 found this case: the value again, with
	// no name, so only the taint check removes it.
	lines[5] = "10:06 ERROR upstream rejected " + value
	h := newHarness(t, nil)
	h.files.files[`C:\data\app.log`] = strings.Join(lines, "\n")

	t.Run("redacted lines with numbers", func(t *testing.T) {
		env := h.runner.View(ViewRequest{Paths: []string{`C:\data\app.log`}, Start: 4, Lines: 4})
		if env.Status != StatusOK || env.Label != ViewLabel {
			t.Fatalf("status = %q (%s), label = %q", env.Status, env.Detail, env.Label)
		}
		result := env.Result.(*ViewResult)
		file := result.Files[0]
		want := "4|10:04 INFO request 4\n5|10:05 X-Api-Key: [REDACTED:key_value]\n6|10:06 ERROR upstream rejected [REDACTED:tainted]\n7|10:07 INFO request 7\n"
		if file.Text != want || file.FirstLine != 4 || file.LastLine != 7 || file.TotalLines != 30 {
			t.Errorf("view = %+v\nwant text %q", file, want)
		}
		if env.Stats.Redactions != 2 {
			t.Errorf("redactions = %d, want 2", env.Stats.Redactions)
		}
		entry := h.audit.entries[len(h.audit.entries)-1]
		if entry.Task != "view" || entry.Model != "" || len(h.engine.requests) != 0 {
			t.Errorf("audit = %+v, engine requests = %d", entry, len(h.engine.requests))
		}
		auditText, _ := json.Marshal(entry)
		wantNoCanary(t, "view audit", string(auditText)+result.String(), value)
	})

	t.Run("range after the end", func(t *testing.T) {
		env := h.runner.View(ViewRequest{Paths: []string{`C:\data\app.log`}, Start: 99})
		if env.Status != StatusOK || !contains(env.Warnings, "a file has no lines in the requested range") {
			t.Errorf("status = %q, warnings = %q", env.Status, env.Warnings)
		}
	})

	t.Run("bad requests", func(t *testing.T) {
		for _, req := range []ViewRequest{{}, {Paths: []string{`C:\data\app.log`}, Lines: maxViewLines + 1}, {Paths: []string{`C:\data\app.log`}, Start: -1}} {
			if env := h.runner.View(req); env.Status != StatusBadRequest {
				t.Errorf("%+v: status = %q, want bad_request", req, env.Status)
			}
		}
	})

	t.Run("the path policy applies", func(t *testing.T) {
		h.files.err = &policy.Error{Code: policy.CodeDeniedName, Path: `C:\data\.env`, Detail: "denied name"}
		defer func() { h.files.err = nil }()
		env := h.runner.View(ViewRequest{Paths: []string{`C:\data\.env`}})
		if env.Status != StatusRefused || env.Result != nil {
			t.Errorf("status = %q, result = %v", env.Status, env.Result)
		}
	})

	t.Run("character limit", func(t *testing.T) {
		long := strings.Repeat(strings.Repeat("x", 400)+"\n", 400)
		h.files.files[`C:\data\long.log`] = long
		env := h.runner.View(ViewRequest{Paths: []string{`C:\data\long.log`, `C:\data\long.log`}, Lines: maxViewLines})
		var size int
		for _, file := range env.Result.(*ViewResult).Files {
			size += len(file.Text)
		}
		if size > maxViewChars || !contains(env.Warnings, viewLimitNotice) {
			t.Errorf("size = %d, warnings = %q", size, env.Warnings)
		}
	})
}

func contains(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}
