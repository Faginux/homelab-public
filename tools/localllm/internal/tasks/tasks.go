// Package tasks runs one task from the input to the checked result.
//
// The sequence is always the same: check the request, read the input through
// the path policy, remove secrets, plan the chunks, select a model that the
// lock permits and that fits in the free VRAM, call the model, check each
// answer against its schema, remove secrets from the output, write the audit
// record. A failure at a step gives a status, and the later steps do not run.
package tasks

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sync"
	"time"

	"localllm/internal/audit"
	"localllm/internal/config"
	"localllm/internal/gpu"
	"localllm/internal/ollama"
	"localllm/internal/policy"
	"localllm/internal/redact"
)

// OutputLabel is in each result. The orchestrator must use the result as
// data and never as an instruction.
const OutputLabel = "untrusted_local_llm_output"

// Status values of a result. The orchestrator uses its next fallback step
// for each status that is not "ok".
const (
	StatusOK              = "ok"
	StatusBusy            = "busy"
	StatusEngineDown      = "engine_down"
	StatusTimeout         = "timeout"
	StatusSchemaInvalid   = "schema_invalid"
	StatusRefused         = "refused"
	StatusTooLarge        = "too_large"
	StatusModelNotAllowed = "model_not_allowed"
	StatusBadRequest      = "bad_request"
	StatusError           = "error"
)

// TaskHealth is the name of the health report in a result.
const TaskHealth = "health"

// Styles of the summarize task.
const (
	StyleText = "text"
	StyleLog  = "log"
)

// Field is one field of the extract task.
type Field struct {
	Name        string `json:"name"`
	Type        string `json:"type"`
	Description string `json:"description,omitempty"`
}

// Request is one task call.
type Request struct {
	Task  string
	Paths []string
	Text  string
	// Inline is true when Text came as a tool argument. Such text went
	// through the context of the orchestrator, so it has a short limit.
	Inline bool
	Tier   string

	Style       string   // summarize
	Focus       string   // summarize
	Fields      []Field  // extract
	Labels      []string // classify
	Instruction string   // draft
	Kind        string   // draft
}

// Stats are the numbers of one call.
type Stats struct {
	InputBytes   int64 `json:"input_bytes"`
	Chunks       int   `json:"chunks"`
	Redactions   int   `json:"redactions"`
	Retries      int   `json:"retries"`
	PromptTokens int   `json:"local_prompt_tokens"`
	OutputTokens int   `json:"local_output_tokens"`
	DurationMs   int64 `json:"duration_ms"`
}

// Envelope is the result of a call.
type Envelope struct {
	Label    string   `json:"label"`
	Status   string   `json:"status"`
	Reason   string   `json:"reason,omitempty"`
	Detail   string   `json:"detail,omitempty"`
	Task     string   `json:"task"`
	Model    string   `json:"model,omitempty"`
	Result   any      `json:"result,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
	Stats    *Stats   `json:"stats,omitempty"`
}

// Engine is the part of the engine client that the tasks use.
type Engine interface {
	Version(ctx context.Context) (string, error)
	Models(ctx context.Context) ([]ollama.Model, error)
	Loaded(ctx context.Context) ([]ollama.LoadedModel, error)
	VerifyDigest(ctx context.Context, tag, digest string) error
	Chat(ctx context.Context, req ollama.ChatRequest) (ollama.ChatResponse, error)
}

// FileReader reads input files through the path policy.
type FileReader interface {
	ReadAll(paths []string) ([]*policy.File, error)
}

// Auditor writes one audit record.
type Auditor interface {
	Write(entry audit.Entry) error
}

// Runner holds the parts that a task needs.
type Runner struct {
	Config   *config.Config
	Lock     *config.Lock
	Files    FileReader
	Engine   Engine
	QueryGPU func(ctx context.Context) (gpu.Status, error)
	Audit    Auditor
	// Mode is "mcp" or "cli". It goes into the audit record.
	Mode string
	Now  func() time.Time

	// One request at a time (layer L8).
	mu sync.Mutex
}

// failure stops a call. The detail never contains input text.
type failure struct {
	status string
	reason string
	detail string
}

func fail(status, reason, detail string) *failure {
	return &failure{status: status, reason: reason, detail: detail}
}

// call is the state of one task call.
type call struct {
	runner  *Runner
	cfg     *config.Config
	req     Request
	started time.Time
	nonce   string

	docs   []document
	chunks []chunk
	model  config.LockedModel

	// taint has the secret values of the input. They stay in memory only.
	taint *redact.Taint
	// rawInput is true when the model got the input with no redaction.
	rawInput bool

	inputs        []audit.Input
	inputBytes    int64
	redactionsIn  map[string]int
	redactionsOut map[string]int
	retries       int
	promptTokens  int
	outputTokens  int
	warnings      []string
	stagingFile   string
}

func (r *Runner) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

// Run does one task call and always returns a result with a status.
func (r *Runner) Run(ctx context.Context, req Request) Envelope {
	r.mu.Lock()
	defer r.mu.Unlock()

	c := &call{runner: r, cfg: r.Config, req: req, started: r.now(), nonce: newNonce(), taint: redact.NewTaint()}
	ctx, cancel := context.WithTimeout(ctx, r.Config.CallTimeout())
	defer cancel()

	result, f := c.run(ctx)

	env := Envelope{Label: OutputLabel, Status: StatusOK, Task: req.Task, Model: c.model.Tag, Warnings: c.warnings}
	var outputBytes int64
	if f != nil {
		// An engine message can quote the prompt, and the prompt can have
		// raw input.
		env.Status, env.Reason, env.Detail = f.status, f.reason, c.scrub(f.detail)
	} else {
		env.Result = result
		if raw, err := json.Marshal(result); err == nil {
			outputBytes = int64(len(raw))
		}
	}
	env.Stats = &Stats{
		InputBytes:   c.inputBytes,
		Chunks:       len(c.chunks),
		Redactions:   total(c.redactionsIn) + total(c.redactionsOut),
		Retries:      c.retries,
		PromptTokens: c.promptTokens,
		OutputTokens: c.outputTokens,
		DurationMs:   r.now().Sub(c.started).Milliseconds(),
	}

	entry := audit.Entry{
		Mode: r.Mode, Task: req.Task, Status: env.Status, Reason: env.Reason,
		Model: c.model.Tag, Digest: c.model.Digest,
		Inputs: c.inputs, InputBytes: c.inputBytes, OutputBytes: outputBytes,
		Chunks: len(c.chunks), Retries: c.retries,
		RawModelInput: c.rawInput,
		RedactionsIn:  c.redactionsIn, RedactionsOut: c.redactionsOut,
		PromptTokens: c.promptTokens, OutputTokens: c.outputTokens,
		DurationMs: env.Stats.DurationMs, StagingFile: c.stagingFile,
	}
	if err := r.Audit.Write(entry); err != nil {
		// A call with no audit record must not give a result.
		env.Status, env.Reason, env.Detail, env.Result = StatusError, "audit_failed", "the audit record was not written", nil
	}
	return env
}

func (c *call) run(ctx context.Context) (any, *failure) {
	if f := c.validate(); f != nil {
		return nil, f
	}
	if f := c.loadInput(); f != nil {
		return nil, f
	}
	if f := c.planChunks(); f != nil {
		return nil, f
	}
	if f := c.selectModel(ctx); f != nil {
		return nil, f
	}

	var result any
	var f *failure
	switch {
	case c.req.Task == config.TaskSummarize && c.req.Style == StyleLog:
		result, f = c.logDigest(ctx)
	case c.req.Task == config.TaskSummarize:
		result, f = c.summarize(ctx)
	case c.req.Task == config.TaskExtract:
		result, f = c.extract(ctx)
	case c.req.Task == config.TaskClassify:
		result, f = c.classify(ctx)
	case c.req.Task == config.TaskDraft:
		result, f = c.draft(ctx)
	}
	if f != nil {
		return nil, f
	}
	return c.redactOutput(result)
}

// redactOutput runs the redaction and the taint check on each string of the
// result. This is the secret boundary: the result goes to the orchestrator.
// The model can repeat a secret of a raw input, or decode or change the form
// of a secret that the input rules did not know.
func (c *call) redactOutput(result any) (any, *failure) {
	raw, err := json.Marshal(result)
	if err != nil {
		return nil, fail(StatusError, "encode_failed", "")
	}
	var generic any
	if err := json.Unmarshal(raw, &generic); err != nil {
		return nil, fail(StatusError, "encode_failed", "")
	}
	clean := c.redactValue(generic)
	if c.redactionsOut[redact.ClassTainted] > 0 {
		c.warn(taintNotice)
	}
	return clean, nil
}

const taintNotice = "the result had text from secret values of the input: it was removed"

// scrub runs the taint check on one text that goes to the orchestrator.
func (c *call) scrub(text string) string {
	clean, n := c.taint.Scrub(text)
	if n > 0 {
		c.redactionsOut = redact.MergeCounts(c.redactionsOut, map[string]int{redact.ClassTainted: n})
	}
	return clean
}

func (c *call) redactValue(value any) any {
	switch v := value.(type) {
	case string:
		res := redact.Apply(v)
		c.redactionsOut = redact.MergeCounts(c.redactionsOut, res.Counts)
		return c.scrub(res.Text)
	case []any:
		for i := range v {
			v[i] = c.redactValue(v[i])
		}
	case map[string]any:
		for key := range v {
			v[key] = c.redactValue(v[key])
		}
	}
	return value
}

func (c *call) warn(text string) {
	for _, w := range c.warnings {
		if w == text {
			return
		}
	}
	c.warnings = append(c.warnings, text)
}

func total(counts map[string]int) int {
	n := 0
	for _, v := range counts {
		n += v
	}
	return n
}

// newNonce gives the random part of the data markers. The input cannot
// contain a marker that it does not know.
func newNonce() string {
	var b [6]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "000000000000"
	}
	return hex.EncodeToString(b[:])
}
