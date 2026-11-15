package tasks

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"strings"

	"localllm/internal/gpu"
	"localllm/internal/ollama"
	"localllm/internal/redact"
	"localllm/internal/schema"
)

//go:embed prompts/*.txt
var promptFiles embed.FS

// temperature is low: the tasks need the same answer for the same input.
const temperature = 0.1

func prompt(name string) string {
	raw, err := promptFiles.ReadFile("prompts/" + name + ".txt")
	if err != nil {
		// The files are in the binary. A missing file is a build error,
		// and the prompt test finds it.
		return ""
	}
	return strings.TrimSpace(string(raw))
}

// selectModel finds the first model for the task that the lock permits,
// that has the digest of the lock, and that fits in the free VRAM. It goes
// from the tier of the request down to the smallest tier.
func (c *call) selectModel(ctx context.Context) *failure {
	r := c.runner
	candidates := c.cfg.ModelCandidates(c.req.Task, c.req.Tier)

	loaded, err := r.Engine.Loaded(ctx)
	if err != nil {
		return engineFailure(err)
	}
	var memory *gpu.Status
	lastDetail := "no model is configured for this task"

	for _, tag := range candidates {
		locked, ok := c.runner.Lock.Find(tag)
		if !ok {
			return fail(StatusModelNotAllowed, "not_in_lock", fmt.Sprintf("the model %s is not in the models lock", tag))
		}
		switch err := r.Engine.VerifyDigest(ctx, locked.Tag, locked.Digest); {
		case errors.Is(err, ollama.ErrDigestMismatch):
			return fail(StatusModelNotAllowed, "digest_mismatch", fmt.Sprintf("the model %s has a digest that is not the digest of the lock", tag))
		case errors.Is(err, ollama.ErrModelNotInstalled):
			return fail(StatusModelNotAllowed, "not_installed", fmt.Sprintf("the model %s is not installed", tag))
		case err != nil:
			return engineFailure(err)
		}

		if locked.VRAMMiB > c.cfg.VRAMBudgetMiB {
			lastDetail = fmt.Sprintf("the model %s needs %d MiB and the budget is %d MiB", tag, locked.VRAMMiB, c.cfg.VRAMBudgetMiB)
			continue
		}
		if isLoaded(loaded, tag) {
			// The model is already in memory: its VRAM is not free, and no load is necessary.
			c.model = locked
			return nil
		}
		if memory == nil {
			status, err := r.QueryGPU(ctx)
			if err != nil {
				// With no VRAM number the load is not safe.
				return fail(StatusBusy, "vram_unknown", "the free VRAM is not available")
			}
			memory = &status
		}
		if gpu.Fits(memory.FreeMiB, locked.VRAMMiB, c.cfg.VRAMMarginMiB) {
			c.model = locked
			return nil
		}
		lastDetail = fmt.Sprintf("the model %s needs %d MiB plus a margin of %d MiB, and %d MiB are free",
			tag, locked.VRAMMiB, c.cfg.VRAMMarginMiB, memory.FreeMiB)
	}
	return fail(StatusBusy, "vram", lastDetail)
}

func isLoaded(loaded []ollama.LoadedModel, tag string) bool {
	for _, m := range loaded {
		if m.Name == tag {
			return true
		}
	}
	return false
}

func engineFailure(err error) *failure {
	var status *ollama.StatusError
	switch {
	case errors.Is(err, ollama.ErrTimeout), errors.Is(err, context.DeadlineExceeded):
		return fail(StatusTimeout, "timeout", "")
	case errors.Is(err, ollama.ErrEngineDown):
		return fail(StatusEngineDown, "engine_down", "")
	case errors.Is(err, ollama.ErrContextExceeded):
		return fail(StatusTooLarge, "context_exceeded", "a chunk has more tokens than the model context: use a smaller chunk_chars or filter the input first")
	case errors.As(err, &status):
		// The engine writes its own message here. The redaction runs on it
		// also, because the message could quote a part of the prompt.
		return fail(StatusError, "engine_http_error", fmt.Sprintf("HTTP status %d: %s", status.Code, redact.Apply(status.Message).Text))
	default:
		return fail(StatusError, "engine_error", "")
	}
}

// userPrompt puts the data between two marker lines with a random part.
// The data cannot close the block, because it does not know the marker.
func (c *call) userPrompt(instructions, label, data string) string {
	var b strings.Builder
	b.WriteString(instructions)
	if label != "" {
		b.WriteString("\n\n")
		b.WriteString(label)
		b.WriteString("\n<<<DATA-" + c.nonce + "\n")
		b.WriteString(data)
		if !strings.HasSuffix(data, "\n") {
			b.WriteString("\n")
		}
		b.WriteString("DATA-" + c.nonce + ">>>")
	}
	return b.String()
}

// chat sends one request to the selected model.
func (c *call) chat(ctx context.Context, user string, sch *schema.Schema, maxTokens int) (ollama.ChatResponse, *failure) {
	req := ollama.ChatRequest{
		Model:       c.model.Tag,
		System:      prompt("system"),
		User:        user,
		MaxTokens:   maxTokens,
		NumCtx:      c.cfg.NumCtx,
		KeepAlive:   c.cfg.KeepAlive,
		Temperature: temperature,
	}
	if sch != nil {
		req.Schema = sch.JSON()
	}
	resp, err := c.runner.Engine.Chat(ctx, req)
	if err != nil {
		return ollama.ChatResponse{}, engineFailure(err)
	}
	c.promptTokens += resp.PromptTokens
	c.outputTokens += resp.OutputTokens
	if resp.PromptTokens+resp.OutputTokens >= c.cfg.NumCtx {
		c.warn("a model call filled the context: the model possibly ignored the start of a chunk")
	}
	return resp, nil
}

// askJSON asks for an answer that agrees with the schema. A bad answer
// gets one retry. The text of a bad answer goes nowhere.
func (c *call) askJSON(ctx context.Context, user string, sch *schema.Schema) (map[string]any, *failure) {
	const attempts = 2
	for attempt := 1; ; attempt++ {
		resp, f := c.chat(ctx, user, sch, c.cfg.MaxOutputTokens)
		if f != nil {
			return nil, f
		}
		value, err := sch.Validate(resp.Content)
		if err == nil {
			return value, nil
		}
		if attempt == attempts {
			return nil, fail(StatusSchemaInvalid, "schema_invalid", "the model answer did not agree with the schema after one retry")
		}
		c.retries++
	}
}
