package ollama

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	digestA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	digestB = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
)

// fakeEngine is a synthetic engine. It records the chat requests.
type fakeEngine struct {
	*httptest.Server
	chatBodies []map[string]any
	chatReply  func(w http.ResponseWriter)
	tagsReply  string
}

func newFakeEngine(t *testing.T) *fakeEngine {
	t.Helper()
	fe := &fakeEngine{
		tagsReply: `{"models":[{"name":"small:1","model":"small:1","digest":"` + digestA + `","size":2500000000}]}`,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"version":"0.40.13"}`)
	})
	mux.HandleFunc("GET /api/tags", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, fe.tagsReply)
	})
	mux.HandleFunc("GET /api/ps", func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"models":[{"name":"small:1","digest":"`+digestA+`","size":3300000000,"size_vram":3300000000}]}`)
	})
	mux.HandleFunc("POST /api/chat", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("the chat request is not JSON: %v", err)
		}
		fe.chatBodies = append(fe.chatBodies, body)
		if fe.chatReply != nil {
			fe.chatReply(w)
			return
		}
		io.WriteString(w, `{"model":"small:1","message":{"role":"assistant","content":"{\"summary\":\"ok\"}"},"done":true,"done_reason":"stop","prompt_eval_count":120,"eval_count":14}`)
	})
	fe.Server = httptest.NewServer(mux)
	t.Cleanup(fe.Close)
	return fe
}

func newClient(t *testing.T, url string, timeout time.Duration) *Client {
	t.Helper()
	c, err := New(url, timeout)
	if err != nil {
		t.Fatalf("New(%q): %v", url, err)
	}
	return c
}

func TestNewRefusesRemoteEngines(t *testing.T) {
	tests := []struct {
		name string
		url  string
		ok   bool
	}{
		{"loopback", "http://127.0.0.1:11434", true},
		{"loopback IPv6", "http://[::1]:11434", true},
		{"other loopback address", "http://127.0.0.2:11434", true},
		{"LAN address", "http://192.0.2.10:11434", false},
		{"public address", "http://203.0.113.5:11434", false},
		{"all interfaces", "http://0.0.0.0:11434", false},
		{"host name", "http://localhost:11434", false},
		{"cloud host name", "http://ollama.example:11434", false},
		{"https", "https://127.0.0.1:11434", false},
		{"no scheme", "127.0.0.1:11434", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := New(tt.url, time.Second)
			if (err == nil) != tt.ok {
				t.Errorf("New(%q) error = %v, want ok = %v", tt.url, err, tt.ok)
			}
		})
	}
}

// The dialer is the second check. It must refuse a remote address also when
// a request gets past the URL check of New.
func TestDialerRefusesRemoteAddress(t *testing.T) {
	c := newClient(t, "http://127.0.0.1:1", time.Second)
	for _, target := range []string{"http://192.0.2.10:11434/api/version", "http://203.0.113.5/"} {
		_, err := c.http.Get(target)
		if err == nil || !strings.Contains(err.Error(), "not a loopback address") {
			t.Errorf("Get(%s) error = %v, want a refusal of the dialer", target, err)
		}
	}
}

func TestReadEndpoints(t *testing.T) {
	fe := newFakeEngine(t)
	c := newClient(t, fe.URL, 5*time.Second)
	ctx := context.Background()

	version, err := c.Version(ctx)
	if err != nil || version != "0.40.13" {
		t.Errorf("Version = %q, %v", version, err)
	}
	models, err := c.Models(ctx)
	if err != nil || len(models) != 1 || models[0].Name != "small:1" || models[0].Digest != digestA {
		t.Errorf("Models = %+v, %v", models, err)
	}
	loaded, err := c.Loaded(ctx)
	if err != nil || len(loaded) != 1 || loaded[0].SizeVRAM != 3300000000 {
		t.Errorf("Loaded = %+v, %v", loaded, err)
	}
}

func TestVerifyDigest(t *testing.T) {
	fe := newFakeEngine(t)
	c := newClient(t, fe.URL, 5*time.Second)
	tests := []struct {
		name   string
		tag    string
		digest string
		want   error
	}{
		{"digest of the lock", "small:1", digestA, nil},
		{"digest with prefix and upper case", "small:1", "sha256:" + strings.ToUpper(digestA), nil},
		{"tag with new content", "small:1", digestB, ErrDigestMismatch},
		{"model that is not installed", "other:1", digestA, ErrModelNotInstalled},
		{"tag with a different case", "Small:1", digestA, ErrModelNotInstalled},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := c.VerifyDigest(context.Background(), tt.tag, tt.digest)
			if !errors.Is(err, tt.want) {
				t.Errorf("VerifyDigest error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestChatRequestShape(t *testing.T) {
	fe := newFakeEngine(t)
	c := newClient(t, fe.URL, 5*time.Second)

	schema := json.RawMessage(`{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}`)
	resp, err := c.Chat(context.Background(), ChatRequest{
		Model: "small:1", System: "system text", User: "user text",
		Schema: schema, MaxTokens: 1500, NumCtx: 8192, KeepAlive: "2m", Temperature: 0.1,
	})
	if err != nil {
		t.Fatalf("Chat: %v", err)
	}
	want := ChatResponse{Content: `{"summary":"ok"}`, PromptTokens: 120, OutputTokens: 14, DoneReason: "stop"}
	if resp != want {
		t.Errorf("Chat = %+v, want %+v", resp, want)
	}

	body := fe.chatBodies[0]
	var keys []string
	for key := range body {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	// The request has exactly these fields. In particular it has no "tools".
	wantKeys := []string{"format", "keep_alive", "messages", "model", "options", "stream", "think"}
	if !reflect.DeepEqual(keys, wantKeys) {
		t.Errorf("request fields = %v, want %v", keys, wantKeys)
	}
	if body["stream"] != false || body["think"] != false {
		t.Errorf("stream = %v, think = %v, want false and false", body["stream"], body["think"])
	}
	if body["keep_alive"] != "2m" || body["model"] != "small:1" {
		t.Errorf("keep_alive = %v, model = %v", body["keep_alive"], body["model"])
	}
	wantOptions := map[string]any{"temperature": 0.1, "num_predict": 1500.0, "num_ctx": 8192.0}
	if !reflect.DeepEqual(body["options"], wantOptions) {
		t.Errorf("options = %v, want %v", body["options"], wantOptions)
	}
	messages := body["messages"].([]any)
	if len(messages) != 2 {
		t.Fatalf("messages = %v, want a system and a user message", messages)
	}
	for i, wantRole := range []string{"system", "user"} {
		message := messages[i].(map[string]any)
		if message["role"] != wantRole || len(message) != 2 {
			t.Errorf("message %d = %v, want only role %q and content", i, message, wantRole)
		}
	}
}

func TestChatWithoutSchemaSendsNoFormat(t *testing.T) {
	fe := newFakeEngine(t)
	c := newClient(t, fe.URL, 5*time.Second)
	if _, err := c.Chat(context.Background(), ChatRequest{Model: "small:1", User: "text"}); err != nil {
		t.Fatalf("Chat: %v", err)
	}
	if _, has := fe.chatBodies[0]["format"]; has {
		t.Error("the request has a format field, want none for free text")
	}
}

func TestErrors(t *testing.T) {
	t.Run("engine down", func(t *testing.T) {
		fe := newFakeEngine(t)
		url := fe.URL
		fe.Close()
		c := newClient(t, url, 2*time.Second)
		_, err := c.Version(context.Background())
		if !errors.Is(err, ErrEngineDown) {
			t.Errorf("error = %v, want ErrEngineDown", err)
		}
	})
	t.Run("timeout", func(t *testing.T) {
		fe := newFakeEngine(t)
		release := make(chan struct{})
		defer close(release)
		fe.chatReply = func(w http.ResponseWriter) { <-release }
		c := newClient(t, fe.URL, 150*time.Millisecond)
		_, err := c.Chat(context.Background(), ChatRequest{Model: "small:1", User: "text"})
		if !errors.Is(err, ErrTimeout) {
			t.Errorf("error = %v, want ErrTimeout", err)
		}
	})
	t.Run("context deadline", func(t *testing.T) {
		fe := newFakeEngine(t)
		release := make(chan struct{})
		defer close(release)
		fe.chatReply = func(w http.ResponseWriter) { <-release }
		c := newClient(t, fe.URL, 5*time.Second)
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		defer cancel()
		_, err := c.Chat(ctx, ChatRequest{Model: "small:1", User: "text"})
		if !errors.Is(err, ErrTimeout) {
			t.Errorf("error = %v, want ErrTimeout", err)
		}
	})
	t.Run("HTTP error with a message", func(t *testing.T) {
		fe := newFakeEngine(t)
		fe.chatReply = func(w http.ResponseWriter) {
			w.WriteHeader(http.StatusNotFound)
			io.WriteString(w, `{"error":"model 'small:1' not found"}`)
		}
		c := newClient(t, fe.URL, 5*time.Second)
		_, err := c.Chat(context.Background(), ChatRequest{Model: "small:1", User: "text"})
		var status *StatusError
		if !errors.As(err, &status) || status.Code != http.StatusNotFound || !strings.Contains(status.Message, "not found") {
			t.Errorf("error = %v, want a StatusError 404 with the engine message", err)
		}
	})
	t.Run("prompt larger than the context", func(t *testing.T) {
		fe := newFakeEngine(t)
		fe.chatReply = func(w http.ResponseWriter) {
			w.WriteHeader(http.StatusBadRequest)
			// The text of engine version 0.40.13.
			io.WriteString(w, `{"error":"request (8709 tokens) exceeds the available context size (8192 tokens), try increasing it"}`)
		}
		c := newClient(t, fe.URL, 5*time.Second)
		_, err := c.Chat(context.Background(), ChatRequest{Model: "small:1", User: "text"})
		if !errors.Is(err, ErrContextExceeded) {
			t.Errorf("error = %v, want ErrContextExceeded", err)
		}
	})
	t.Run("long error text is cut", func(t *testing.T) {
		fe := newFakeEngine(t)
		fe.chatReply = func(w http.ResponseWriter) {
			w.WriteHeader(http.StatusInternalServerError)
			io.WriteString(w, `{"error":"`+strings.Repeat("e", 5000)+`"}`)
		}
		c := newClient(t, fe.URL, 5*time.Second)
		_, err := c.Chat(context.Background(), ChatRequest{Model: "small:1", User: "text"})
		var status *StatusError
		if !errors.As(err, &status) || len(status.Message) != maxErrorChars {
			t.Errorf("error = %v, want a message of %d characters", err, maxErrorChars)
		}
	})
	t.Run("answer that is not JSON", func(t *testing.T) {
		fe := newFakeEngine(t)
		fe.chatReply = func(w http.ResponseWriter) { io.WriteString(w, "<html>") }
		c := newClient(t, fe.URL, 5*time.Second)
		if _, err := c.Chat(context.Background(), ChatRequest{Model: "small:1", User: "text"}); err == nil {
			t.Error("Chat accepted an answer that is not JSON")
		}
	})
	t.Run("answer above the size limit", func(t *testing.T) {
		fe := newFakeEngine(t)
		fe.chatReply = func(w http.ResponseWriter) {
			io.WriteString(w, `{"message":{"content":"`+strings.Repeat("x", maxResponseBytes)+`"}}`)
		}
		c := newClient(t, fe.URL, 5*time.Second)
		_, err := c.Chat(context.Background(), ChatRequest{Model: "small:1", User: "text"})
		if err == nil || !strings.Contains(err.Error(), "larger than") {
			t.Errorf("error = %v, want a size refusal", err)
		}
	})
}

func TestRedirectIsNotFollowed(t *testing.T) {
	var hits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		io.WriteString(w, `{"version":"redirected"}`)
	}))
	defer target.Close()
	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/api/version", http.StatusFound)
	}))
	defer redirector.Close()

	c := newClient(t, redirector.URL, 5*time.Second)
	version, err := c.Version(context.Background())
	var status *StatusError
	if !errors.As(err, &status) || status.Code != http.StatusFound {
		t.Errorf("Version = %q, %v, want a StatusError 302", version, err)
	}
	if hits.Load() != 0 {
		t.Errorf("the redirect target got %d requests, want 0", hits.Load())
	}
}

// The request type must stay as small as it is. This test fails when a
// field is added, for example "tools" or "images".
func TestWireRequestFields(t *testing.T) {
	want := []string{"format", "keep_alive", "messages", "model", "options", "stream", "think"}
	var got []string
	typ := reflect.TypeOf(wireRequest{})
	for i := 0; i < typ.NumField(); i++ {
		got = append(got, strings.Split(typ.Field(i).Tag.Get("json"), ",")[0])
	}
	sort.Strings(got)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("the JSON keys of the chat request changed:\n got %v\nwant %v", got, want)
	}
}
