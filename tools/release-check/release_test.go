package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"
	"unicode/utf8"
)

// ---- fakes ----

type fakeRegistry struct {
	tags    map[string][]string // repo -> tags
	digests map[string]string   // repo:tag -> digest
	fail    map[string]error    // repo -> error for every call
}

func (f *fakeRegistry) Tags(_ context.Context, ref imageRef) ([]string, error) {
	if err := f.fail[ref.Repo]; err != nil {
		return nil, err
	}
	return f.tags[ref.Repo], nil
}

func (f *fakeRegistry) Digest(_ context.Context, ref imageRef, tag string) (string, error) {
	if err := f.fail[ref.Repo]; err != nil {
		return "", err
	}
	d, ok := f.digests[ref.Repo+":"+tag]
	if !ok {
		return "", errors.New("no such tag")
	}
	return d, nil
}

type fakeNotifier struct {
	sent []string
	fail error
}

func (n *fakeNotifier) Send(_ context.Context, text string) error {
	if n.fail != nil {
		return n.fail
	}
	n.sent = append(n.sent, text)
	return nil
}

// ---- parsing ----

func TestParseImage(t *testing.T) {
	cases := []struct {
		in       string
		ok       bool
		registry string
		repo     string
		name     string
		tag      string
		digest   string
	}{
		{"mariadb:10.11.19@sha256:abc", true, hubRegistry, "library/mariadb", "mariadb", "10.11.19", "sha256:abc"},
		{"docker.io/apache/tika:4.1.0", true, hubRegistry, "apache/tika", "apache/tika", "4.1.0", ""},
		{"docker.io/library/redis:7", true, hubRegistry, "library/redis", "redis", "7", ""},
		{"ghcr.io/bitwarden/lite:2026.9.2", true, "ghcr.io", "bitwarden/lite", "bitwarden/lite", "2026.9.2", ""},
		{"netplexflix/umtk:latest@sha256:def", true, hubRegistry, "netplexflix/umtk", "netplexflix/umtk", "latest", "sha256:def"},
		{"ghcr.io/fuzzygrim/yamtrack", false, "", "", "", "", ""},
		{"ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}", false, "", "", "", "", ""},
		{"localhost:5000/app", false, "", "", "", "", ""},
	}
	for _, c := range cases {
		got, ok := parseImage(c.in)
		if ok != c.ok {
			t.Errorf("%s: ok = %v, want %v", c.in, ok, c.ok)
			continue
		}
		if !ok {
			continue
		}
		if got.Registry != c.registry || got.Repo != c.repo || got.Name != c.name || got.Tag != c.tag || got.Digest != c.digest {
			t.Errorf("%s: got %+v", c.in, got)
		}
	}
}

func TestPickCandidates(t *testing.T) {
	tags := []string{
		"2.11.4", "2.11.5", "2.12.0", "2.12.0-rc1", "2.12.0-beta.2", "3.0.0", "3.1.0",
		"2.11", "latest", "2.99.0-alpine", "1.0.0",
	}
	pin, _ := parseVersion("2.11.4")

	safe, major := pickCandidates(trackMajor, pin, tags)
	if safe == nil || safe.String() != "2.12.0" {
		t.Errorf("major track: safe = %v, want 2.12.0 (pre-releases and variants must be ignored)", safe)
	}
	if major == nil || major.String() != "3.1.0" {
		t.Errorf("major track: major = %v, want 3.1.0", major)
	}

	safe, major = pickCandidates(trackMinor, pin, tags)
	if safe == nil || safe.String() != "2.11.5" {
		t.Errorf("minor track: safe = %v, want 2.11.5", safe)
	}
	if major == nil || major.String() != "3.1.0" {
		t.Errorf("minor track: major = %v, want 3.1.0", major)
	}

	safe, major = pickCandidates(trackAny, pin, tags)
	if safe == nil || safe.String() != "3.1.0" || major != nil {
		t.Errorf("any track: safe = %v, major = %v", safe, major)
	}
}

func TestPickCandidatesKeepsVariantAndPrefix(t *testing.T) {
	pin, _ := parseVersion("v4.5.8-full")
	safe, _ := pickCandidates(trackMajor, pin, []string{"v4.5.9-full", "v4.6.0", "4.7.0-full", "v4.5.9-full-rc1", "v4.5.9"})
	if safe == nil || safe.String() != "v4.5.9-full" {
		t.Errorf("safe = %v, want v4.5.9-full", safe)
	}

	cal, _ := parseVersion("2026.9.2")
	safe, _ = pickCandidates(trackAny, cal, []string{"2026.10.0", "2026.9.10", "2026.9"})
	if safe == nil || safe.String() != "2026.10.0" {
		t.Errorf("calendar version: safe = %v, want 2026.10.0 (numeric order, not text order)", safe)
	}
}

func TestScanPins(t *testing.T) {
	repo := fstest.MapFS{
		"nodes/the-grid/bw/docker-compose.yml":  {Data: []byte("services:\n  a:\n    image: ghcr.io/bitwarden/lite:2026.9.2@sha256:aa\n  b:\n    image: \"mariadb:10.11.19\"\n  c:\n    # image: old/thing:1.2.3\n    image: redis:7\n")},
		"nodes/the-grid/dvb/docker-compose.yml": {Data: []byte("image: offen/docker-volume-backup:v2.49.1\n")},
		"stacks/immich/docker-compose.yml": {Data: []byte("image: ghcr.io/immich-app/immich-server:${V:-release}\nimage: netplexflix/umtk:latest@sha256:bb\n")},
		"stacks/immich/notes.txt":          {Data: []byte("image: ignored/file:1.2.3\n")},
	}
	pins, skips, err := scanPins(repo, []root{{"nodes/the-grid", "the-grid"}, {"stacks", "V4"}})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, p := range pins {
		got = append(got, p.Ref.Name+"@"+p.Place)
	}
	want := "bitwarden/lite@the-grid bw,mariadb@the-grid bw,offen/docker-volume-backup@the-grid dvb,netplexflix/umtk@V4 immich"
	// sorted by full reference: docker hub first (registry-1...), then ghcr.io
	for _, w := range strings.Split(want, ",") {
		if !contains(got, w) {
			t.Errorf("missing pin %s in %v", w, got)
		}
	}
	if len(pins) != 4 {
		t.Errorf("got %d pins (%v), want 4", len(pins), got)
	}
	if len(skips) != 2 { // redis:7 (floating) and the variable
		t.Errorf("got %d skips (%v), want 2", len(skips), skips)
	}
}

// ---- registry over HTTP ----

func TestHTTPRegistryAuthAndPagination(t *testing.T) {
	var tokenCalls int
	mux := http.NewServeMux()
	var srv *httptest.Server
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		tokenCalls++
		if r.URL.Query().Get("scope") != "repository:org/app:pull" {
			http.Error(w, "bad scope", 400)
			return
		}
		w.Write([]byte(`{"token":"t0k"}`))
	})
	mux.HandleFunc("/v2/org/app/tags/list", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer t0k" {
			w.Header().Set("Www-Authenticate", `Bearer realm="`+srv.URL+`/token",service="reg",scope="repository:org/app:pull"`)
			w.WriteHeader(401)
			return
		}
		if r.URL.Query().Get("last") == "" {
			w.Header().Set("Link", `</v2/org/app/tags/list?n=1000&last=1.0.1>; rel="next"`)
			w.Write([]byte(`{"tags":["1.0.0","1.0.1"]}`))
			return
		}
		w.Write([]byte(`{"tags":["1.0.2"]}`))
	})
	mux.HandleFunc("/v2/org/app/manifests/1.0.2", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			w.WriteHeader(405)
			return
		}
		if r.Header.Get("Authorization") != "Bearer t0k" {
			w.Header().Set("Www-Authenticate", `Bearer realm="`+srv.URL+`/token",service="reg",scope="repository:org/app:pull"`)
			w.WriteHeader(401)
			return
		}
		w.Header().Set("Docker-Content-Digest", "sha256:feed")
	})
	srv = httptest.NewServer(mux)
	defer srv.Close()

	reg := newHTTPRegistry(srv.Client())
	reg.baseURL = srv.URL
	ref := imageRef{Registry: "x", Repo: "org/app", Tag: "1.0.0"}

	tags, err := reg.Tags(context.Background(), ref)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(tags, ",") != "1.0.0,1.0.1,1.0.2" {
		t.Errorf("tags = %v", tags)
	}
	d, err := reg.Digest(context.Background(), ref, "1.0.2")
	if err != nil || d != "sha256:feed" {
		t.Errorf("digest = %q, err = %v", d, err)
	}
	if tokenCalls != 1 {
		t.Errorf("token requested %d times, want 1 (cache)", tokenCalls)
	}
}

func TestHTTPRegistryRetriesRateLimit(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls < 3 {
			w.Header().Set("Retry-After", "7")
			w.WriteHeader(429)
			return
		}
		w.Write([]byte(`{"tags":["1.0.0"]}`))
	}))
	defer srv.Close()
	var waits []time.Duration
	reg := newHTTPRegistry(srv.Client())
	reg.baseURL = srv.URL
	reg.sleep = func(_ context.Context, d time.Duration) error { waits = append(waits, d); return nil }

	tags, err := reg.Tags(context.Background(), imageRef{Repo: "a/b"})
	if err != nil || len(tags) != 1 {
		t.Fatalf("tags = %v, err = %v", tags, err)
	}
	if len(waits) != 2 || waits[0] != 7*time.Second {
		t.Errorf("waits = %v, want 2 waits of Retry-After (7 s)", waits)
	}
}

func TestHTTPRegistryError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }))
	defer srv.Close()
	reg := newHTTPRegistry(srv.Client())
	reg.baseURL = srv.URL
	reg.sleep = func(context.Context, time.Duration) error { return nil }
	if _, err := reg.Tags(context.Background(), imageRef{Repo: "a/b"}); err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("err = %v, want HTTP 500", err)
	}
}

// ---- full rounds ----

type env struct {
	repo   string
	state  string
	reg    *fakeRegistry
	notify *fakeNotifier
	out    *bytes.Buffer
}

const bitwardenPin = "ghcr.io/bitwarden/lite:2026.9.2@sha256:old"

func newEnv(t *testing.T, bitwardenImage string) *env {
	t.Helper()
	dir := t.TempDir()
	writeCompose(t, dir, bitwardenImage)
	return &env{
		repo:  dir,
		state: filepath.Join(t.TempDir(), "state.json"),
		reg: &fakeRegistry{
			tags: map[string][]string{
				"bitwarden/lite":  {"2026.9.2", "2026.9.1"},
				"library/mariadb": {"10.11.19", "10.11.19-ubi"},
			},
			digests: map[string]string{
				"bitwarden/lite:2026.9.2":  "sha256:old",
				"bitwarden/lite:2026.10.0": "sha256:new",
			},
			fail: map[string]error{},
		},
		notify: &fakeNotifier{},
		out:    &bytes.Buffer{},
	}
}

func writeCompose(t *testing.T, dir, bitwardenImage string) {
	t.Helper()
	path := filepath.Join(dir, "nodes", "the-grid", "bitwarden", "docker-compose.yml")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	body := "services:\n  bw:\n    image: " + bitwardenImage + "\n  db:\n    image: mariadb:10.11.19\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (e *env) run(t *testing.T, dryRun bool) error {
	t.Helper()
	c := &checker{
		repo: e.repo,
		cfg: config{
			Roots: []root{{"nodes/the-grid", "the-grid"}},
			Images: map[string]imageConfig{
				"bitwarden/lite": {Track: trackAny, Notes: "https://example.test/bw"},
				"mariadb":        {Track: trackMinor},
			},
		},
		reg:       e.reg,
		notify:    e.notify,
		statePath: e.state,
		hostLabel: "the-grid",
		log:       e.out,
		dryRun:    dryRun,
	}
	return c.run(context.Background())
}

func TestRoundNoChangeIsSilent(t *testing.T) {
	e := newEnv(t, bitwardenPin)
	if err := e.run(t, false); err != nil {
		t.Fatal(err)
	}
	if len(e.notify.sent) != 0 {
		t.Errorf("sent %v, want silence", e.notify.sent)
	}
}

func TestRoundNewVersionRebuildAndMajor(t *testing.T) {
	e := newEnv(t, bitwardenPin)
	e.reg.tags["bitwarden/lite"] = append(e.reg.tags["bitwarden/lite"], "2026.10.0", "2026.10.0-rc1")
	e.reg.digests["bitwarden/lite:2026.9.2"] = "sha256:rebuilt"
	e.reg.tags["library/mariadb"] = append(e.reg.tags["library/mariadb"], "11.4.2")
	if err := e.run(t, false); err != nil {
		t.Fatal(err)
	}
	if len(e.notify.sent) != 1 {
		t.Fatalf("sent %d messages, want 1", len(e.notify.sent))
	}
	msg := e.notify.sent[0]
	for _, want := range []string{
		"📦 Release immagini pinnate",
		"📦 bitwarden/lite — the-grid bitwarden",
		"⬆️ 2026.9.2 → 2026.10.0",
		"🔗 https://example.test/bw",
		"🔁 2026.9.2 ricostruita (stesso tag, digest nuovo)",
		"📦 mariadb — the-grid bitwarden",
		"🆕 major 10.11.19 → 11.4.2 (da valutare, non nel comando)",
		"incolla in Claude Code",
		"<pre>",
		"- bitwarden/lite (the-grid bitwarden): 2026.9.2 → 2026.10.0 (note: https://example.test/bw)",
		"il deploy lo faccio io",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("message misses %q:\n%s", want, msg)
		}
	}
	if strings.Contains(msg, "rc1") {
		t.Errorf("pre-release in message:\n%s", msg)
	}
	// The command holds the safe update only: a rebuild of the old tag is moot, and a
	// major is for Faginux to decide.
	command := msg[strings.Index(msg, "<pre>"):]
	if strings.Contains(command, "stesso tag") || strings.Contains(command, "mariadb") {
		t.Errorf("command holds more than the safe update:\n%s", command)
	}

	// Second round, same registry: silence.
	if err := e.run(t, false); err != nil {
		t.Fatal(err)
	}
	if len(e.notify.sent) != 1 {
		t.Errorf("second round sent a message again")
	}
}

func TestRoundPinCaughtUpSendsRientrato(t *testing.T) {
	e := newEnv(t, bitwardenPin)
	e.reg.tags["bitwarden/lite"] = append(e.reg.tags["bitwarden/lite"], "2026.10.0")
	if err := e.run(t, false); err != nil {
		t.Fatal(err)
	}
	// Faginux updates the pin in the compose.
	writeCompose(t, e.repo, "ghcr.io/bitwarden/lite:2026.10.0@sha256:new")
	if err := e.run(t, false); err != nil {
		t.Fatal(err)
	}
	if len(e.notify.sent) != 2 || !strings.Contains(e.notify.sent[1], "Rientrato: bitwarden/lite:2026.9.2") {
		t.Errorf("sent = %v, want a Rientrato for the old pin", e.notify.sent)
	}
}

func TestRoundRegistryErrorIsReportedOnceAndRecovers(t *testing.T) {
	e := newEnv(t, bitwardenPin)
	e.reg.fail["bitwarden/lite"] = errors.New("HTTP 503")

	err := e.run(t, false)
	if err == nil {
		t.Fatal("want a non-zero result when an image cannot be checked")
	}
	if len(e.notify.sent) != 1 || !strings.Contains(e.notify.sent[0], "ERRORE bitwarden/lite: tags: HTTP 503") {
		t.Fatalf("sent = %v", e.notify.sent)
	}

	// Same error again: no second message.
	_ = e.run(t, false)
	if len(e.notify.sent) != 1 {
		t.Errorf("error repeated in a second message")
	}

	// The registry answers again.
	delete(e.reg.fail, "bitwarden/lite")
	if err := e.run(t, false); err != nil {
		t.Fatal(err)
	}
	if len(e.notify.sent) != 2 || !strings.Contains(e.notify.sent[1], "Rientrato: bitwarden/lite (registro di nuovo raggiungibile)") {
		t.Errorf("sent = %v", e.notify.sent)
	}
}

func TestRoundTelegramFailureKeepsState(t *testing.T) {
	e := newEnv(t, bitwardenPin)
	e.reg.tags["bitwarden/lite"] = append(e.reg.tags["bitwarden/lite"], "2026.10.0")
	e.notify.fail = errors.New("telegram down")
	if err := e.run(t, false); err == nil {
		t.Fatal("want the send error")
	}
	if _, err := os.Stat(e.state); err == nil {
		t.Fatal("state saved after a failed send")
	}
	e.notify.fail = nil
	if err := e.run(t, false); err != nil {
		t.Fatal(err)
	}
	if len(e.notify.sent) != 1 {
		t.Errorf("notice lost after a failed send: %v", e.notify.sent)
	}
}

func TestDryRunDoesNotSaveState(t *testing.T) {
	e := newEnv(t, bitwardenPin)
	e.reg.tags["bitwarden/lite"] = append(e.reg.tags["bitwarden/lite"], "2026.10.0")
	if err := e.run(t, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e.state); err == nil {
		t.Error("dry run saved the state: the first real run would be silent")
	}
}

func newsReport(name string, safe string) report {
	return report{Finding: &finding{Name: name, Places: "the-grid stack", Pin: "1.0.0", Safe: safe, Notes: "https://example.test/" + name}}
}

func TestBuildMessageLeavesWholePartsOutAndKeepsCommand(t *testing.T) {
	var reports []report
	for i := 0; i < 60; i++ {
		reports = append(reports, newsReport(fmt.Sprintf("image-%02d", i), "1.1.0"))
	}
	msg := buildMessage("the-grid", reports)
	if len(msg) > 4096 {
		t.Errorf("message is %d bytes, Telegram takes 4096", len(msg))
	}
	for _, want := range []string{"[...troncato: altre ", "<pre>", "</pre>"} {
		if !strings.Contains(msg, want) {
			t.Errorf("message misses %q", want)
		}
	}
	if strings.Count(msg, "<pre>") != 1 || strings.Count(msg, "</pre>") != 1 {
		t.Error("the pre block is not balanced")
	}
	if !utf8.ValidString(msg) {
		t.Error("truncation cut inside a UTF-8 sequence")
	}
}

func TestBuildMessageEscapesHTML(t *testing.T) {
	msg := buildMessage("the-grid", []report{{Line: "ERRORE x: tags: <html> & co"}})
	if !strings.Contains(msg, "ERRORE x: tags: &lt;html&gt; &amp; co") {
		t.Errorf("error text not escaped:\n%s", msg)
	}
}

func TestBuildMessageMajorOnlyHasNoCommand(t *testing.T) {
	f := finding{Name: "tika", Places: "the-grid stack", Pin: "4.1.0", Major: "5.0.0"}
	msg := buildMessage("the-grid", []report{{Finding: &f}})
	if strings.Contains(msg, "<pre>") {
		t.Errorf("a command for a major only:\n%s", msg)
	}
	if !strings.Contains(msg, "Solo nuove major") {
		t.Errorf("no note about the majors:\n%s", msg)
	}
}

func TestTelegramSendsHTMLParseMode(t *testing.T) {
	var got url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		got = r.PostForm
	}))
	defer srv.Close()
	tn := &telegramNotifier{botToken: "T", chatID: "1", http: srv.Client(), baseURL: srv.URL}
	if err := tn.Send(context.Background(), "<pre>x</pre>"); err != nil {
		t.Fatal(err)
	}
	if got.Get("parse_mode") != "HTML" || got.Get("text") != "<pre>x</pre>" {
		t.Errorf("form = %v", got)
	}
}

func TestBuildMessageLongLineIsClipped(t *testing.T) {
	msg := buildMessage("the-grid", []report{{Line: strings.Repeat("→", 3000)}})
	if len(msg) > 4096 {
		t.Fatalf("message is %d bytes", len(msg))
	}
	if strings.ContainsRune(msg, '\uFFFD') {
		t.Error("truncation cut inside a UTF-8 sequence")
	}
}

func TestTelegramErrorHidesToken(t *testing.T) {
	tn := &telegramNotifier{botToken: "SECRET-TOKEN", chatID: "1", http: &http.Client{}, baseURL: "http://127.0.0.1:1"}
	err := tn.Send(context.Background(), "x")
	if err == nil {
		t.Fatal("want an error")
	}
	if strings.Contains(err.Error(), "SECRET-TOKEN") {
		t.Errorf("token in error: %v", err)
	}
}

func TestLoadConfigRejectsTypos(t *testing.T) {
	path := filepath.Join(t.TempDir(), "c.json")
	os.WriteFile(path, []byte(`{"roots":[{"path":"a","host":"H"}],"images":{"x":{"trak":"major"}}}`), 0o644)
	if _, err := loadConfig(path); err == nil {
		t.Error("unknown key accepted")
	}
	os.WriteFile(path, []byte(`{"roots":[{"path":"a","host":"H"}],"images":{"x":{"track":"sometimes"}}}`), 0o644)
	if _, err := loadConfig(path); err == nil {
		t.Error("unknown track accepted")
	}
}

func TestRepoConfigIsValid(t *testing.T) {
	if _, err := loadConfig("config.json"); err != nil {
		t.Fatal(err)
	}
}
