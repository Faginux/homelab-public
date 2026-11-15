// Package ollama is the HTTP client for the local engine (layers L1 and L2
// of the plan).
//
// The client connects only to a loopback address. It uses no proxy and
// follows no redirect. A chat request has no "tools" field: the model gets
// text and returns text, and it cannot act.
package ollama

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	dialTimeout      = 5 * time.Second
	maxResponseBytes = 4 << 20
	maxErrorChars    = 200
)

// Errors that the caller maps to a result status.
var (
	ErrEngineDown        = errors.New("ollama: the engine does not answer")
	ErrTimeout           = errors.New("ollama: the request timed out")
	ErrModelNotInstalled = errors.New("ollama: the model is not installed")
	ErrDigestMismatch    = errors.New("ollama: the model digest is different from the lock")
	// ErrContextExceeded: the engine refuses a prompt that has more tokens
	// than the context. It does not cut the prompt.
	ErrContextExceeded = errors.New("ollama: the prompt is larger than the model context")
)

// StatusError is an HTTP answer with a status that is not 200.
type StatusError struct {
	Code    int
	Message string
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("ollama: HTTP status %d: %s", e.Code, e.Message)
}

// Client talks to one engine.
type Client struct {
	base string
	http *http.Client
}

// New makes a client. The URL must have a loopback IP address.
func New(baseURL string, timeout time.Duration) (*Client, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("ollama: parse the engine URL: %w", err)
	}
	if u.Scheme != "http" {
		return nil, fmt.Errorf("ollama: the scheme %q is not http", u.Scheme)
	}
	if ip := net.ParseIP(u.Hostname()); ip == nil || !ip.IsLoopback() {
		return nil, fmt.Errorf("ollama: the host %q is not a loopback IP address", u.Hostname())
	}

	dialer := &net.Dialer{Timeout: dialTimeout}
	transport := &http.Transport{
		// No proxy from the environment: the text must not go through a
		// different program.
		Proxy: nil,
		// The second check of the address, at connection time.
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, _, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
				return nil, fmt.Errorf("ollama: refused a connection to %s: not a loopback address", addr)
			}
			return dialer.DialContext(ctx, network, addr)
		},
	}
	return &Client{
		base: "http://" + u.Host,
		http: &http.Client{
			Transport: transport,
			Timeout:   timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}, nil
}

// Model is an installed model.
type Model struct {
	Name   string `json:"name"`
	Digest string `json:"digest"`
	Size   int64  `json:"size"`
}

// LoadedModel is a model in memory.
type LoadedModel struct {
	Name     string `json:"name"`
	Digest   string `json:"digest"`
	Size     int64  `json:"size"`
	SizeVRAM int64  `json:"size_vram"`
}

// Version returns the version of the engine.
func (c *Client) Version(ctx context.Context) (string, error) {
	var out struct {
		Version string `json:"version"`
	}
	if err := c.do(ctx, http.MethodGet, "/api/version", nil, &out); err != nil {
		return "", err
	}
	return out.Version, nil
}

// Models returns the installed models.
func (c *Client) Models(ctx context.Context) ([]Model, error) {
	var out struct {
		Models []Model `json:"models"`
	}
	if err := c.do(ctx, http.MethodGet, "/api/tags", nil, &out); err != nil {
		return nil, err
	}
	return out.Models, nil
}

// Loaded returns the models in memory.
func (c *Client) Loaded(ctx context.Context) ([]LoadedModel, error) {
	var out struct {
		Models []LoadedModel `json:"models"`
	}
	if err := c.do(ctx, http.MethodGet, "/api/ps", nil, &out); err != nil {
		return nil, err
	}
	return out.Models, nil
}

// VerifyDigest checks that the installed model with this tag has the digest
// of the lock. A tag can get new content. The digest cannot.
func (c *Client) VerifyDigest(ctx context.Context, tag, wantDigest string) error {
	models, err := c.Models(ctx)
	if err != nil {
		return err
	}
	for _, m := range models {
		if m.Name != tag {
			continue
		}
		if normalizeDigest(m.Digest) != normalizeDigest(wantDigest) {
			return fmt.Errorf("%w: tag %s", ErrDigestMismatch, tag)
		}
		return nil
	}
	return fmt.Errorf("%w: tag %s", ErrModelNotInstalled, tag)
}

func normalizeDigest(digest string) string {
	return strings.TrimPrefix(strings.ToLower(strings.TrimSpace(digest)), "sha256:")
}

// ChatRequest is one call of the model.
type ChatRequest struct {
	Model  string
	System string
	User   string
	// Schema is the JSON schema of the answer. If it is empty, the answer
	// is free text.
	Schema      json.RawMessage
	MaxTokens   int
	NumCtx      int
	KeepAlive   string
	Temperature float64
}

// ChatResponse is the answer of the model.
type ChatResponse struct {
	Content      string
	PromptTokens int
	OutputTokens int
	DoneReason   string
}

// The wire types have exactly the fields that localllm sends. There is no
// field for tools, images or raw mode.
type wireRequest struct {
	Model     string          `json:"model"`
	Messages  []wireMessage   `json:"messages"`
	Stream    bool            `json:"stream"`
	Think     bool            `json:"think"`
	Format    json.RawMessage `json:"format,omitempty"`
	KeepAlive string          `json:"keep_alive"`
	Options   wireOptions     `json:"options"`
}

type wireMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type wireOptions struct {
	Temperature float64 `json:"temperature"`
	NumPredict  int     `json:"num_predict"`
	NumCtx      int     `json:"num_ctx"`
}

type wireResponse struct {
	Message         wireMessage `json:"message"`
	DoneReason      string      `json:"done_reason"`
	PromptEvalCount int         `json:"prompt_eval_count"`
	EvalCount       int         `json:"eval_count"`
}

// Chat sends one request and waits for the full answer.
func (c *Client) Chat(ctx context.Context, req ChatRequest) (ChatResponse, error) {
	wire := wireRequest{
		Model: req.Model,
		Messages: []wireMessage{
			{Role: "system", Content: req.System},
			{Role: "user", Content: req.User},
		},
		Stream:    false,
		Think:     false,
		Format:    req.Schema,
		KeepAlive: req.KeepAlive,
		Options: wireOptions{
			Temperature: req.Temperature,
			NumPredict:  req.MaxTokens,
			NumCtx:      req.NumCtx,
		},
	}
	var out wireResponse
	if err := c.do(ctx, http.MethodPost, "/api/chat", wire, &out); err != nil {
		return ChatResponse{}, err
	}
	return ChatResponse{
		Content:      out.Message.Content,
		PromptTokens: out.PromptEvalCount,
		OutputTokens: out.EvalCount,
		DoneReason:   out.DoneReason,
	}, nil
}

func (c *Client) do(ctx context.Context, method, path string, body, out any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("ollama: encode the request: %w", err)
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, reader)
	if err != nil {
		return fmt.Errorf("ollama: make the request: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return transportError(err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
	if err != nil {
		return transportError(err)
	}
	if len(raw) > maxResponseBytes {
		return fmt.Errorf("ollama: the answer is larger than %d bytes", maxResponseBytes)
	}
	if resp.StatusCode != http.StatusOK {
		message := errorMessage(raw)
		if resp.StatusCode == http.StatusBadRequest && strings.Contains(message, "exceeds the available context size") {
			return fmt.Errorf("%w: %s", ErrContextExceeded, message)
		}
		return &StatusError{Code: resp.StatusCode, Message: message}
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("ollama: decode the answer of %s: %w", path, err)
	}
	return nil
}

func transportError(err error) error {
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &netErr) && netErr.Timeout()) {
		return fmt.Errorf("%w: %v", ErrTimeout, err)
	}
	if errors.Is(err, context.Canceled) {
		return err
	}
	return fmt.Errorf("%w: %v", ErrEngineDown, err)
}

// errorMessage returns the short error text of the engine. The engine
// writes its own message there, not the prompt.
func errorMessage(raw []byte) string {
	var body struct {
		Error string `json:"error"`
	}
	message := "no error text"
	if json.Unmarshal(raw, &body) == nil && body.Error != "" {
		message = body.Error
	}
	if len(message) > maxErrorChars {
		message = message[:maxErrorChars]
	}
	return message
}
