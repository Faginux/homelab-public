package tasks

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"localllm/internal/redact"
)

const draftNotice = "Draft from a local model. It is not reviewed. Do not use it before a review."

// Draft is the result of the draft task. The text of the draft is in the
// staging file, not in the result.
type Draft struct {
	StagingFile string `json:"staging_file"`
	Bytes       int    `json:"bytes"`
	Lines       int    `json:"lines"`
}

// draft asks the model for free text and writes it to the staging folder
// (layer L6). This is the only write of a task, and the path has no part
// that comes from the caller or from the model.
func (c *call) draft(ctx context.Context) (any, *failure) {
	// The instruction is caller text, but a pasted secret must not go to
	// the model also from here.
	instruction := redact.Apply(c.req.Instruction)
	c.redactionsIn = redact.MergeCounts(c.redactionsIn, instruction.Counts)

	var data strings.Builder
	for _, ch := range c.chunks {
		data.WriteString("--- " + c.docs[ch.doc].name + " ---\n" + ch.text + "\n")
	}
	instructions := prompt("draft") + "\nKind of draft: " + c.req.Kind + "\nInstruction:\n" + instruction.Text
	label := ""
	if len(c.chunks) > 0 {
		label = "Input: reference material"
	}
	user := c.userPrompt(instructions, label, data.String())

	var text string
	const attempts = 2
	for attempt := 1; ; attempt++ {
		resp, f := c.chat(ctx, user, nil, c.cfg.MaxDraftTokens)
		if f != nil {
			return nil, f
		}
		if resp.DoneReason == "length" {
			c.warn("the draft reached the output limit: it is possibly not complete")
		}
		if text = cleanDraft(resp.Content); text != "" {
			break
		}
		if attempt == attempts {
			return nil, fail(StatusSchemaInvalid, "empty_draft", "the model gave no text after one retry")
		}
		c.retries++
	}

	// The orchestrator reads the staging file, so the draft goes through
	// the same boundary as a result.
	clean := redact.Apply(text)
	c.redactionsOut = redact.MergeCounts(c.redactionsOut, clean.Counts)
	draftText := c.scrub(clean.Text)
	if c.redactionsOut[redact.ClassTainted] > 0 {
		c.warn(taintNotice)
	}

	kind := draftKinds[c.req.Kind]
	content := draftText + "\n"
	if kind.header != "" {
		content = fmt.Sprintf(kind.header, draftNotice) + content
	}
	path, err := c.writeStaging(content, kind.ext)
	if err != nil {
		return nil, fail(StatusError, "staging_write_failed", "the draft was not written to the staging folder")
	}
	c.stagingFile = path
	return Draft{StagingFile: path, Bytes: len(content), Lines: strings.Count(content, "\n")}, nil
}

// cleanDraft removes a code fence around the full answer. Small models add
// it often.
func cleanDraft(text string) string {
	text = strings.TrimSpace(text)
	if !strings.HasPrefix(text, "```") || !strings.HasSuffix(text, "```") || len(text) < 6 {
		return text
	}
	inner := text[3 : len(text)-3]
	if i := strings.IndexByte(inner, '\n'); i >= 0 {
		// The first line is the fence with an optional language name.
		inner = inner[i+1:]
	} else {
		return text
	}
	if strings.Contains(inner, "```") {
		// More than one fenced block: the fences are part of the content.
		return text
	}
	return strings.TrimSpace(inner)
}

// writeStaging writes the draft to <staging>/<date>/<time>-draft-<hash><ext>.
// It never replaces a file.
func (c *call) writeStaging(content, ext string) (string, error) {
	now := c.runner.now()
	dir := filepath.Join(c.cfg.StagingDir, now.Format("2006-01-02"))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("make the staging folder: %w", err)
	}
	sum := sha256.Sum256([]byte(content))
	name := now.Format("150405") + "-draft-" + hex.EncodeToString(sum[:4]) + ext
	path := filepath.Join(dir, name)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return "", fmt.Errorf("make the staging file: %w", err)
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		return "", fmt.Errorf("write the staging file: %w", err)
	}
	if err := f.Close(); err != nil {
		return "", fmt.Errorf("close the staging file: %w", err)
	}
	return path, nil
}
