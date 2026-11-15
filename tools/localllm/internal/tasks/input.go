package tasks

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"localllm/internal/audit"
	"localllm/internal/config"
	"localllm/internal/policy"
	"localllm/internal/redact"
)

const (
	textInputName   = "(text)"
	maxLogLineChars = 500
)

// document is one input after the redaction.
type document struct {
	name  string
	text  string
	lines []string
}

// chunk is the part of a document that goes into one model call.
type chunk struct {
	doc       int
	text      string
	part      int
	parts     int
	firstLine int
	lastLine  int
	cut       bool
}

// loadInput reads the files through the path policy, checks the text
// input, and removes secrets from both.
func (c *call) loadInput() *failure {
	if len(c.req.Paths) > 0 {
		files, err := c.runner.Files.ReadAll(c.req.Paths)
		if err != nil {
			for _, path := range c.req.Paths {
				c.inputs = append(c.inputs, audit.Input{Path: path})
			}
			code := policy.CodeOf(err)
			if code == "" {
				return fail(StatusError, "input_read_failed", "")
			}
			// The text of a policy refusal has the path and the rule only.
			return fail(StatusRefused, code, err.Error())
		}
		for _, file := range files {
			c.inputs = append(c.inputs, audit.Input{Path: file.Canonical, SHA256: file.SHA256, Bytes: file.Bytes})
			c.inputBytes += file.Bytes
			c.addDocument(file.Name, file.Text)
		}
	}
	if c.req.Text != "" {
		size := int64(len(c.req.Text))
		if size > c.cfg.MaxCallBytes {
			return fail(StatusTooLarge, "call_too_large", fmt.Sprintf("the text is larger than %d bytes", c.cfg.MaxCallBytes))
		}
		text, err := policy.Text([]byte(c.req.Text))
		if err != nil {
			return fail(StatusRefused, policy.CodeOf(err), "the text input is not text")
		}
		sum := sha256.Sum256([]byte(c.req.Text))
		c.inputs = append(c.inputs, audit.Input{Path: textInputName, SHA256: hex.EncodeToString(sum[:]), Bytes: size})
		c.inputBytes += size
		c.addDocument(textInputName, text)
	}
	if c.inputBytes > c.cfg.MaxCallBytes {
		return fail(StatusTooLarge, "call_too_large", fmt.Sprintf("the input of one call is larger than %d bytes", c.cfg.MaxCallBytes))
	}
	return nil
}

func (c *call) addDocument(name, text string) {
	res := redact.Apply(text)
	c.redactionsIn = redact.MergeCounts(c.redactionsIn, res.Counts)
	c.docs = append(c.docs, document{name: name, text: res.Text})
}

// planChunks cuts the documents for the task. It runs before the model
// selection, so an input that is too large makes no engine request.
func (c *call) planChunks() *failure {
	limit := c.cfg.ChunkChars
	if c.req.Task != config.TaskDraft && c.inputIsEmpty() {
		return fail(StatusBadRequest, "empty_input", "the input has no text")
	}
	switch {
	case c.req.Task == config.TaskClassify:
		if len(c.docs) > maxClassifyDocs {
			return fail(StatusTooLarge, "too_many_documents", fmt.Sprintf("one classify call permits %d documents", maxClassifyDocs))
		}
		// One label for each document: the start of the document is sufficient.
		for i, doc := range c.docs {
			head, cut := clip(doc.text, limit)
			c.chunks = append(c.chunks, chunk{doc: i, text: head, part: 1, parts: 1, cut: cut})
			if cut {
				c.warn("classify used only the first part of a document that is larger than one chunk")
			}
		}
		return nil

	case c.req.Task == config.TaskDraft:
		// The instruction, the reference material and the draft must fit
		// in one context.
		budget := c.cfg.PromptCharBudget(c.cfg.MaxDraftTokens) - len(c.req.Instruction)
		size := 0
		for i, doc := range c.docs {
			size += len(doc.text)
			c.chunks = append(c.chunks, chunk{doc: i, text: doc.text, part: 1, parts: 1})
		}
		if size > budget {
			c.chunks = nil
			return fail(StatusTooLarge, "reference_too_large",
				fmt.Sprintf("the reference material has %d characters, and this draft has space for %d", size, max(budget, 0)))
		}
		return nil

	case c.req.Task == config.TaskSummarize && c.req.Style == StyleLog:
		for i := range c.docs {
			c.docs[i].lines = splitLines(c.docs[i].text)
			c.chunks = append(c.chunks, numberedChunks(i, c.docs[i].lines, limit)...)
		}

	default:
		for i, doc := range c.docs {
			parts := splitChunks(doc.text, limit)
			for n, part := range parts {
				c.chunks = append(c.chunks, chunk{doc: i, text: part, part: n + 1, parts: len(parts)})
			}
		}
	}

	if len(c.chunks) > c.cfg.MaxChunks {
		needed := len(c.chunks)
		c.chunks = nil
		return fail(StatusTooLarge, "too_many_chunks",
			fmt.Sprintf("the input needs %d chunks and the limit is %d: filter the input first", needed, c.cfg.MaxChunks))
	}
	return nil
}

func (c *call) inputIsEmpty() bool {
	for _, doc := range c.docs {
		if strings.TrimSpace(doc.text) != "" {
			return false
		}
	}
	return true
}

func splitLines(text string) []string {
	lines := strings.Split(strings.TrimRight(text, "\r\n"), "\n")
	for i, line := range lines {
		lines[i] = strings.TrimRight(line, "\r")
	}
	return lines
}

// splitChunks cuts text into parts of maxChars bytes at most. It cuts at a
// line end when that is possible.
func splitChunks(text string, maxChars int) []string {
	var parts []string
	var current strings.Builder
	flush := func() {
		if current.Len() > 0 {
			parts = append(parts, current.String())
			current.Reset()
		}
	}
	for len(text) > 0 {
		line := text
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			line = text[:i+1]
		}
		text = text[len(line):]

		if current.Len()+len(line) > maxChars {
			flush()
		}
		for len(line) > maxChars {
			piece, _ := clipBytes(line, maxChars)
			parts = append(parts, piece)
			line = line[len(piece):]
		}
		current.WriteString(line)
	}
	flush()
	if len(parts) == 0 {
		parts = []string{""}
	}
	return parts
}

// numberedChunks gives each line its number, so that the model can refer to
// a line and the code can check the reference.
func numberedChunks(doc int, lines []string, maxChars int) []chunk {
	var chunks []chunk
	var current strings.Builder
	first := 1
	flush := func(last int) {
		if current.Len() > 0 {
			chunks = append(chunks, chunk{doc: doc, text: current.String(), firstLine: first, lastLine: last})
			current.Reset()
		}
	}
	for i, line := range lines {
		short, _ := clip(line, maxLogLineChars)
		numbered := strconv.Itoa(i+1) + "| " + short + "\n"
		if current.Len()+len(numbered) > maxChars {
			flush(i)
			first = i + 1
		}
		current.WriteString(numbered)
	}
	flush(len(lines))
	for i := range chunks {
		chunks[i].part, chunks[i].parts = i+1, len(chunks)
	}
	return chunks
}

// clip cuts text to maxChars characters. The second result is true when
// the text was cut.
func clip(text string, maxChars int) (string, bool) {
	if utf8.RuneCountInString(text) <= maxChars {
		return text, false
	}
	n := 0
	for i := range text {
		if n == maxChars {
			return text[:i], true
		}
		n++
	}
	return text, false
}

// clipBytes cuts text to maxBytes bytes at most, at a character border.
func clipBytes(text string, maxBytes int) (string, bool) {
	if len(text) <= maxBytes {
		return text, false
	}
	end := maxBytes
	for end > 0 && !utf8.RuneStart(text[end]) {
		end--
	}
	if end == 0 {
		end = maxBytes
	}
	return text[:end], true
}

// clipMark cuts text and shows that it was cut.
func clipMark(text string, maxChars int) string {
	short, cut := clip(strings.TrimSpace(text), maxChars)
	if cut {
		return short + "…"
	}
	return short
}

// label names the chunk for the model. It has the file name, not the path.
func (c *call) label(ch chunk) string {
	name := c.docs[ch.doc].name
	if ch.parts > 1 {
		return fmt.Sprintf("Input: %s (part %d of %d)", name, ch.part, ch.parts)
	}
	return "Input: " + name
}
