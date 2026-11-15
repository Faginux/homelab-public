// Package config loads and checks the settings of localllm.
//
// The real config file is outside the repository. Each limit has a ceiling in
// this code: a config file can make a limit lower, but it cannot make it higher.
package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"time"
)

// Ceilings and floors from the safety architecture of the plan (L3, L5, L8).
const (
	MaxFileBytesCeiling   = 2 << 20
	MaxCallBytesCeiling   = 8 << 20
	MaxInlineCharsCeiling = 4000
	MaxOutputTokensCeil   = 1500
	MaxDraftTokensCeil    = 4000
	VRAMMarginFloorMiB    = 1024
	RequestTimeoutMinSec  = 60
	RequestTimeoutMaxSec  = 120
	CallTimeoutMaxSec     = 600
	KeepAliveMax          = 2 * time.Minute
	RetentionMaxDays      = 30
)

// Numbers for the size of a prompt. The engine refuses a prompt that has
// more tokens than the context, and it does not keep space for the answer.
// Thus this code keeps the space: the chunk size has a limit that comes
// from the context size. A log line with numbers and timestamps has about
// 1.6 characters for each token (measured with the engine on 2026-11-15),
// so the calculation uses 1.5. Ordinary prose has about 4.
const (
	denseCharsPerToken   = 1.5
	promptOverheadTokens = 500
	minPromptChars       = 1000
)

// Task names. They are also the keys of Config.Models.
const (
	TaskSummarize = "summarize"
	TaskExtract   = "extract"
	TaskClassify  = "classify"
	TaskDraft     = "draft"
	defaultTask   = "default"
)

// Tier names, from the smallest model to the largest.
const (
	TierS = "s"
	TierM = "m"
)

// Config is the content of the config file.
type Config struct {
	OllamaURL    string   `json:"ollama_url"`
	AllowedRoots []string `json:"allowed_roots"`
	StagingDir   string   `json:"staging_dir"`
	AuditDir     string   `json:"audit_dir"`
	ModelsLock   string   `json:"models_lock"`

	// Models gives a model tag for each task and tier. The key "default"
	// applies to a task that has no entry of its own.
	Models map[string]map[string]string `json:"models"`

	VRAMBudgetMiB int `json:"vram_budget_mib"`
	VRAMMarginMiB int `json:"vram_margin_mib"`

	MaxFileBytes    int64 `json:"max_file_bytes"`
	MaxCallBytes    int64 `json:"max_call_bytes"`
	MaxInlineChars  int   `json:"max_inline_chars"`
	MaxOutputTokens int   `json:"max_output_tokens"`
	MaxDraftTokens  int   `json:"max_draft_tokens"`

	NumCtx     int `json:"num_ctx"`
	ChunkChars int `json:"chunk_chars"`
	MaxChunks  int `json:"max_chunks"`

	RequestTimeoutSeconds int    `json:"request_timeout_seconds"`
	CallTimeoutSeconds    int    `json:"call_timeout_seconds"`
	KeepAlive             string `json:"keep_alive"`
	AuditRetentionDays    int    `json:"audit_retention_days"`
}

// Load reads the config file, sets the defaults and checks the result.
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	cfg, err := Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("config %s: %w", path, err)
	}
	return cfg, nil
}

// Parse decodes a config document. An unknown field is an error, because a
// wrong field name must not silently give a default value.
func Parse(raw []byte) (*Config, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var cfg Config
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func (c *Config) applyDefaults() {
	setDefault(&c.VRAMMarginMiB, VRAMMarginFloorMiB)
	setDefault(&c.MaxFileBytes, int64(MaxFileBytesCeiling))
	setDefault(&c.MaxCallBytes, int64(MaxCallBytesCeiling))
	setDefault(&c.MaxInlineChars, MaxInlineCharsCeiling)
	setDefault(&c.MaxOutputTokens, MaxOutputTokensCeil)
	setDefault(&c.MaxDraftTokens, 3000)
	setDefault(&c.NumCtx, 8192)
	setDefault(&c.ChunkChars, 8000)
	setDefault(&c.MaxChunks, 16)
	setDefault(&c.RequestTimeoutSeconds, RequestTimeoutMaxSec)
	setDefault(&c.CallTimeoutSeconds, 300)
	setDefault(&c.AuditRetentionDays, RetentionMaxDays)
	if c.KeepAlive == "" {
		c.KeepAlive = "2m"
	}
}

func setDefault[T int | int64](field *T, value T) {
	if *field == 0 {
		*field = value
	}
}

// Validate returns all the problems of the config in one error.
func (c *Config) Validate() error {
	var errs []error
	add := func(format string, args ...any) {
		errs = append(errs, fmt.Errorf(format, args...))
	}

	if err := checkLoopbackURL(c.OllamaURL); err != nil {
		add("ollama_url: %w", err)
	}
	if len(c.AllowedRoots) == 0 {
		add("allowed_roots: at least one root is necessary")
	}
	for _, root := range c.AllowedRoots {
		if !filepath.IsAbs(root) {
			add("allowed_roots: %q is not an absolute path", root)
		}
	}
	for name, dir := range map[string]string{
		"staging_dir": c.StagingDir,
		"audit_dir":   c.AuditDir,
		"models_lock": c.ModelsLock,
	} {
		if !filepath.IsAbs(dir) {
			add("%s: %q is not an absolute path", name, dir)
		}
	}

	checkRange(add, "vram_budget_mib", int64(c.VRAMBudgetMiB), 1, 1<<20)
	checkRange(add, "vram_margin_mib", int64(c.VRAMMarginMiB), VRAMMarginFloorMiB, 1<<20)
	checkRange(add, "max_file_bytes", c.MaxFileBytes, 1, MaxFileBytesCeiling)
	checkRange(add, "max_call_bytes", c.MaxCallBytes, 1, MaxCallBytesCeiling)
	checkRange(add, "max_inline_chars", int64(c.MaxInlineChars), 1, MaxInlineCharsCeiling)
	checkRange(add, "max_output_tokens", int64(c.MaxOutputTokens), 1, MaxOutputTokensCeil)
	checkRange(add, "max_draft_tokens", int64(c.MaxDraftTokens), 1, MaxDraftTokensCeil)
	checkRange(add, "num_ctx", int64(c.NumCtx), 2048, 32768)
	checkRange(add, "chunk_chars", int64(c.ChunkChars), 1000, 64000)
	checkRange(add, "max_chunks", int64(c.MaxChunks), 1, 64)
	checkRange(add, "request_timeout_seconds", int64(c.RequestTimeoutSeconds), RequestTimeoutMinSec, RequestTimeoutMaxSec)
	checkRange(add, "call_timeout_seconds", int64(c.CallTimeoutSeconds), int64(c.RequestTimeoutSeconds), CallTimeoutMaxSec)
	checkRange(add, "audit_retention_days", int64(c.AuditRetentionDays), 1, RetentionMaxDays)

	if budget := c.PromptCharBudget(c.MaxOutputTokens); c.ChunkChars > budget {
		add("chunk_chars: %d is more than %d, the largest chunk that leaves space for the answer in a context of %d tokens", c.ChunkChars, budget, c.NumCtx)
	}
	if budget := c.PromptCharBudget(c.MaxDraftTokens); budget < minPromptChars {
		add("num_ctx: %d tokens leave no space for a draft of %d tokens", c.NumCtx, c.MaxDraftTokens)
	}

	keepAlive, err := time.ParseDuration(c.KeepAlive)
	switch {
	case err != nil:
		add("keep_alive: %w", err)
	case keepAlive <= 0 || keepAlive > KeepAliveMax:
		add("keep_alive: %s is not in the range from 1s to %s", c.KeepAlive, KeepAliveMax)
	}

	if err := checkModels(c.Models); err != nil {
		add("models: %w", err)
	}
	return errors.Join(errs...)
}

func checkRange(add func(string, ...any), name string, value, low, high int64) {
	if value < low || value > high {
		add("%s: %d is not in the range from %d to %d", name, value, low, high)
	}
}

// checkLoopbackURL accepts only http and a loopback IP literal. A host name
// is refused, because a hosts file can point it at a remote address.
func checkLoopbackURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("parse: %w", err)
	}
	if u.Scheme != "http" {
		return fmt.Errorf("scheme %q is not http", u.Scheme)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return errors.New("only scheme, address and port are permitted")
	}
	ip := net.ParseIP(u.Hostname())
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("host %q is not a loopback IP address", u.Hostname())
	}
	if u.Port() == "" {
		return errors.New("the port is necessary")
	}
	return nil
}

func checkModels(models map[string]map[string]string) error {
	if models[defaultTask][TierS] == "" {
		return errors.New(`the entry "default" must have a model for tier "s"`)
	}
	knownTasks := map[string]bool{
		defaultTask: true, TaskSummarize: true, TaskExtract: true, TaskClassify: true, TaskDraft: true,
	}
	for task, tiers := range models {
		if !knownTasks[task] {
			return fmt.Errorf("unknown task %q", task)
		}
		for tier, tag := range tiers {
			if tier != TierS && tier != TierM {
				return fmt.Errorf("task %q: unknown tier %q", task, tier)
			}
			if tag == "" {
				return fmt.Errorf("task %q, tier %q: the model tag is empty", task, tier)
			}
		}
	}
	return nil
}

// ModelCandidates returns the model tags for a task, from the tier that the
// caller wants down to the smallest tier. The caller uses the first model
// that fits in the free VRAM.
func (c *Config) ModelCandidates(task, tier string) []string {
	order := []string{TierS}
	if tier == TierM {
		order = []string{TierM, TierS}
	}
	var tags []string
	for _, t := range order {
		tag := c.Models[task][t]
		if tag == "" {
			tag = c.Models[defaultTask][t]
		}
		if tag != "" && !contains(tags, tag) {
			tags = append(tags, tag)
		}
	}
	return tags
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// PromptCharBudget returns the largest number of input characters of one
// model call that leaves space in the context for the fixed part of the
// prompt and for an answer of outputTokens tokens.
func (c *Config) PromptCharBudget(outputTokens int) int {
	return int(float64(c.NumCtx-outputTokens-promptOverheadTokens) * denseCharsPerToken)
}

// RequestTimeout is the time limit of one HTTP request to the engine.
func (c *Config) RequestTimeout() time.Duration {
	return time.Duration(c.RequestTimeoutSeconds) * time.Second
}

// CallTimeout is the time limit of one complete task call.
func (c *Config) CallTimeout() time.Duration {
	return time.Duration(c.CallTimeoutSeconds) * time.Second
}
