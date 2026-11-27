package config

import (
	"encoding/json"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// validDoc returns a config document that passes the checks. A test changes
// one field to make one failure.
func validDoc(t *testing.T) map[string]any {
	t.Helper()
	dir := t.TempDir()
	return map[string]any{
		"ollama_url":      "http://127.0.0.1:11434",
		"allowed_roots":   []string{filepath.Join(dir, "root")},
		"staging_dir":     filepath.Join(dir, "staging"),
		"audit_dir":       filepath.Join(dir, "logs"),
		"models_lock":     filepath.Join(dir, "models.lock.json"),
		"vram_budget_mib": 7926,
		"models": map[string]any{
			"default":  map[string]string{"s": "small:1", "m": "medium:1"},
			"classify": map[string]string{"s": "tiny:1"},
		},
	}
}

func parseDoc(t *testing.T, doc map[string]any) (*Config, error) {
	t.Helper()
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return Parse(raw)
}

func TestParseDefaults(t *testing.T) {
	cfg, err := parseDoc(t, validDoc(t))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	checks := []struct {
		name      string
		got, want int64
	}{
		{"max_file_bytes", cfg.MaxFileBytes, 2 << 20},
		{"max_call_bytes", cfg.MaxCallBytes, 8 << 20},
		{"max_inline_chars", int64(cfg.MaxInlineChars), 4000},
		{"max_output_tokens", int64(cfg.MaxOutputTokens), 1500},
		{"vram_margin_mib", int64(cfg.VRAMMarginMiB), 1024},
		{"request_timeout_seconds", int64(cfg.RequestTimeoutSeconds), 120},
		{"audit_retention_days", int64(cfg.AuditRetentionDays), 30},
		{"chunk_chars", int64(cfg.ChunkChars), 8000},
		{"classify input with no classify_chars", int64(cfg.ClassifyInputChars()), 8000},
		{"prompt budget for a result", int64(cfg.PromptCharBudget(cfg.MaxOutputTokens)), 9288},
		{"prompt budget for a draft", int64(cfg.PromptCharBudget(cfg.MaxDraftTokens)), 7038},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("%s = %d, want %d", c.name, c.got, c.want)
		}
	}
	if cfg.KeepAlive != "2m" {
		t.Errorf("keep_alive = %q, want 2m", cfg.KeepAlive)
	}
}

// The example in the repository must stay a valid config.
func TestExampleConfigIsValid(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("the example has Windows paths")
	}
	if _, err := Load(filepath.Join("..", "..", "config.example.json")); err != nil {
		t.Errorf("config.example.json: %v", err)
	}
}

func TestParseRefuses(t *testing.T) {
	tests := []struct {
		name    string
		change  func(doc map[string]any)
		wantErr string
	}{
		{"remote engine", func(d map[string]any) { d["ollama_url"] = "http://192.0.2.10:11434" }, "ollama_url"},
		{"host name engine", func(d map[string]any) { d["ollama_url"] = "http://localhost:11434" }, "ollama_url"},
		{"https engine", func(d map[string]any) { d["ollama_url"] = "https://127.0.0.1:11434" }, "ollama_url"},
		{"engine with path", func(d map[string]any) { d["ollama_url"] = "http://127.0.0.1:11434/v1" }, "ollama_url"},
		{"engine with user", func(d map[string]any) { d["ollama_url"] = "http://u@127.0.0.1:11434" }, "ollama_url"},
		{"engine without port", func(d map[string]any) { d["ollama_url"] = "http://127.0.0.1" }, "ollama_url"},
		{"no roots", func(d map[string]any) { d["allowed_roots"] = []string{} }, "allowed_roots"},
		{"relative root", func(d map[string]any) { d["allowed_roots"] = []string{"relative/dir"} }, "allowed_roots"},
		{"relative staging", func(d map[string]any) { d["staging_dir"] = "staging" }, "staging_dir"},
		{"file limit above ceiling", func(d map[string]any) { d["max_file_bytes"] = (2 << 20) + 1 }, "max_file_bytes"},
		{"call limit above ceiling", func(d map[string]any) { d["max_call_bytes"] = (8 << 20) + 1 }, "max_call_bytes"},
		{"inline limit above ceiling", func(d map[string]any) { d["max_inline_chars"] = 4001 }, "max_inline_chars"},
		{"output limit above ceiling", func(d map[string]any) { d["max_output_tokens"] = 1501 }, "max_output_tokens"},
		{"margin below floor", func(d map[string]any) { d["vram_margin_mib"] = 512 }, "vram_margin_mib"},
		{"no budget", func(d map[string]any) { delete(d, "vram_budget_mib") }, "vram_budget_mib"},
		{"timeout too short", func(d map[string]any) { d["request_timeout_seconds"] = 30 }, "request_timeout_seconds"},
		{"timeout too long", func(d map[string]any) { d["request_timeout_seconds"] = 121 }, "request_timeout_seconds"},
		{"keep alive too long", func(d map[string]any) { d["keep_alive"] = "10m" }, "keep_alive"},
		{"keep alive forever", func(d map[string]any) { d["keep_alive"] = "-1s" }, "keep_alive"},
		{"retention too long", func(d map[string]any) { d["audit_retention_days"] = 31 }, "audit_retention_days"},
		{"no default model", func(d map[string]any) { d["models"] = map[string]any{"classify": map[string]string{"s": "x"}} }, "models"},
		{"unknown task", func(d map[string]any) {
			d["models"] = map[string]any{"default": map[string]string{"s": "x"}, "shell": map[string]string{"s": "x"}}
		}, "unknown task"},
		{"unknown tier", func(d map[string]any) {
			d["models"] = map[string]any{"default": map[string]string{"s": "x", "xl": "y"}}
		}, "unknown tier"},
		{"unknown field", func(d map[string]any) { d["tools"] = true }, "unknown field"},
		{"chunk that leaves no space for the answer", func(d map[string]any) { d["chunk_chars"] = 9289 }, "chunk_chars"},
		{"chunk too large for a small context", func(d map[string]any) { d["num_ctx"] = 4096; d["chunk_chars"] = 4000 }, "chunk_chars"},
		{"context too small for a draft", func(d map[string]any) { d["num_ctx"] = 4096; d["chunk_chars"] = 1000 }, "num_ctx"},
		{"classify input too small", func(d map[string]any) { d["classify_chars"] = 999 }, "classify_chars"},
		{"classify input that leaves no space for the answer", func(d map[string]any) { d["classify_chars"] = 9289 }, "classify_chars"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			doc := validDoc(t)
			tt.change(doc)
			_, err := parseDoc(t, doc)
			if err == nil {
				t.Fatal("Parse accepted the config, want an error")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("error = %q, want it to contain %q", err, tt.wantErr)
			}
		})
	}
}

func TestModelCandidates(t *testing.T) {
	cfg, err := parseDoc(t, validDoc(t))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	tests := []struct {
		name       string
		task, tier string
		want       []string
	}{
		{"default tier is small", TaskSummarize, "", []string{"small:1"}},
		{"medium falls back to small", TaskSummarize, TierM, []string{"medium:1", "small:1"}},
		{"task entry wins", TaskClassify, TierS, []string{"tiny:1"}},
		{"task entry with default for the missing tier", TaskClassify, TierM, []string{"medium:1", "tiny:1"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := cfg.ModelCandidates(tt.task, tt.tier)
			if strings.Join(got, ",") != strings.Join(tt.want, ",") {
				t.Errorf("ModelCandidates(%q, %q) = %v, want %v", tt.task, tt.tier, got, tt.want)
			}
		})
	}
}

func TestParseLock(t *testing.T) {
	digest := strings.Repeat("ab", 32)
	tests := []struct {
		name    string
		doc     string
		wantErr string
	}{
		{"valid", `{"models":[{"tag":"small:1","digest":"` + digest + `","vram_mib":3158}]}`, ""},
		{"prefix and upper case", `{"models":[{"tag":"small:1","digest":"sha256:` + strings.ToUpper(digest) + `","vram_mib":1}]}`, ""},
		{"empty lock", `{"models":[]}`, ""},
		{"short digest", `{"models":[{"tag":"small:1","digest":"abcd","vram_mib":1}]}`, "digest"},
		{"no vram", `{"models":[{"tag":"small:1","digest":"` + digest + `"}]}`, "vram_mib"},
		{"empty tag", `{"models":[{"tag":"","digest":"` + digest + `","vram_mib":1}]}`, "tag is empty"},
		{"cloud model", `{"models":[{"tag":"big:120b-cloud","digest":"` + digest + `","vram_mib":1}]}`, "cloud"},
		{"same tag two times", `{"models":[{"tag":"a:1","digest":"` + digest + `","vram_mib":1},{"tag":"a:1","digest":"` + digest + `","vram_mib":1}]}`, "two times"},
		{"unknown field", `{"models":[],"allow_all":true}`, "unknown field"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			lock, err := ParseLock([]byte(tt.doc))
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("ParseLock: %v", err)
				}
				for _, m := range lock.Models {
					if m.Digest != digest {
						t.Errorf("digest = %q, want the normalized form %q", m.Digest, digest)
					}
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("error = %v, want it to contain %q", err, tt.wantErr)
			}
		})
	}
}

func TestLockFind(t *testing.T) {
	lock, err := ParseLock([]byte(`{"models":[{"tag":"small:1","digest":"` + strings.Repeat("0", 64) + `","vram_mib":3158}]}`))
	if err != nil {
		t.Fatalf("ParseLock: %v", err)
	}
	if m, ok := lock.Find("small:1"); !ok || m.VRAMMiB != 3158 {
		t.Errorf("Find(small:1) = %+v, %v", m, ok)
	}
	if _, ok := lock.Find("other:1"); ok {
		t.Error("Find(other:1) found a model that is not in the lock")
	}
}
