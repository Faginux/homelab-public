package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// This value is in the fields that the watchdog must NOT read (IP, keys, trace). No
// test must find it in messages, logs or state.
const leakCanary = "DATO-CHE-NON-DEVE-USCIRE"

type fakeServer struct{ name, state, err string }

type fakeKomodo struct {
	servers []fakeServer
	down    bool
}

func (f *fakeKomodo) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/read" ||
			r.Header.Get("x-api-key") != "k" || r.Header.Get("x-api-secret") != "s" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if f.down {
			http.Error(w, `{"error":"database down"}`, http.StatusInternalServerError)
			return
		}
		var req struct {
			Type string `json:"type"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Type != "ListServers" {
			t.Errorf("richiesta inattesa: %q (%v)", req.Type, err)
			http.Error(w, `{"error":"unexpected"}`, http.StatusBadRequest)
			return
		}
		var list []any
		for _, s := range f.servers {
			info := map[string]any{
				"state": s.state, "region": "", "address": nil,
				"public_ip": "203.0.113.7-" + leakCanary, "public_key": leakCanary,
				"send_unreachable_alerts": true, "version": "v2.3.3", "err": nil,
			}
			if s.err != "" {
				info["err"] = map[string]any{"error": s.err, "trace": []string{leakCanary}}
			}
			list = append(list, map[string]any{"id": "id-" + s.name, "name": s.name, "tags": []string{}, "info": info})
		}
		json.NewEncoder(w).Encode(list)
	}
}

type recordNotifier struct {
	sent []string
	fail error
}

func (r *recordNotifier) Send(_ context.Context, text string) error {
	if r.fail != nil {
		return r.fail
	}
	r.sent = append(r.sent, text)
	return nil
}

type harness struct {
	t         *testing.T
	komodo    *fakeKomodo
	srv       *httptest.Server
	notify    *recordNotifier
	statePath string
	now       time.Time
	log       bytes.Buffer
	expect    []string
}

func newHarness(t *testing.T, servers ...fakeServer) *harness {
	h := &harness{
		t:         t,
		komodo:    &fakeKomodo{servers: servers},
		notify:    &recordNotifier{},
		statePath: filepath.Join(t.TempDir(), "state.json"),
		now:       time.Date(2026, 9, 28, 14, 0, 0, 0, time.Local),
	}
	h.srv = httptest.NewServer(h.komodo.handler(t))
	t.Cleanup(h.srv.Close)
	return h
}

// tick does one run and moves the clock 5 minutes forward, as the timer does.
func (h *harness) tick() error {
	w := &watcher{
		api:       &komodoClient{baseURL: h.srv.URL, apiKey: "k", apiSecret: "s", http: h.srv.Client()},
		notify:    h.notify,
		statePath: h.statePath,
		hostLabel: "scope",
		expect:    h.expect,
		threshold: 2,
		now:       func() time.Time { return h.now },
		log:       &h.log,
	}
	err := w.run(context.Background())
	h.now = h.now.Add(5 * time.Minute)
	return err
}

func (h *harness) mustTick(n int) {
	h.t.Helper()
	for range n {
		if err := h.tick(); err != nil {
			h.t.Fatalf("giro fallito: %v", err)
		}
	}
}

func (h *harness) set(name, state, errText string) {
	for i := range h.komodo.servers {
		if h.komodo.servers[i].name == name {
			h.komodo.servers[i].state, h.komodo.servers[i].err = state, errText
			return
		}
	}
	h.t.Fatalf("server %s non nel finto Komodo", name)
}

func (h *harness) wantSent(n int) {
	h.t.Helper()
	if len(h.notify.sent) != n {
		h.t.Fatalf("messaggi inviati: %d, attesi %d\n%s", len(h.notify.sent), n, strings.Join(h.notify.sent, "\n---\n"))
	}
}

func (h *harness) lastContains(parts ...string) {
	h.t.Helper()
	last := h.notify.sent[len(h.notify.sent)-1]
	for _, p := range parts {
		if !strings.Contains(last, p) {
			h.t.Errorf("l'ultimo messaggio non contiene %q:\n%s", p, last)
		}
	}
}

// lastHeader checks the first line of the last message: the uniform format of the
// "Ops" bot (CENSIMENTO-BOT-TELEGRAM.md) with the expected status emoji.
func (h *harness) lastHeader(icon string) {
	h.t.Helper()
	last := h.notify.sent[len(h.notify.sent)-1]
	header, _, _ := strings.Cut(last, "\n")
	if want := icon + " 🍓 scope · 🐕 Komodo watchdog"; header != want {
		h.t.Errorf("intestazione %q, attesa %q", header, want)
	}
}

func twoServers() []fakeServer {
	return []fakeServer{{"the-grid", "Ok", ""}, {"arcade", "Ok", ""}}
}

func TestAllOkIsSilent(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.mustTick(3)
	h.wantSent(0)
	if !strings.Contains(h.log.String(), "arcade: Ok") {
		t.Errorf("il log deve riportare lo stato grezzo di ogni Server:\n%s", h.log.String())
	}
}

func TestOutageAlertsOnceThenRecovers(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.set("arcade", "NotOk", "Periphery disconnected")

	h.mustTick(1) // 14:00, first failure: below the threshold
	h.wantSent(0)
	h.mustTick(1) // 14:05, second in a row: alert
	h.wantSent(1)
	h.lastHeader("🔴")
	h.lastContains("🔴 Server arcade NON risponde", "alle 14:00", "2 di fila", "stato NotOk: Periphery disconnected")
	if strings.Contains(h.notify.sent[0], "the-grid") {
		t.Errorf("the-grid e' sano, non deve comparire:\n%s", h.notify.sent[0])
	}

	h.mustTick(2) // 14:10, 14:15: still down, no duplicate
	h.wantSent(1)

	h.set("arcade", "Ok", "")
	h.mustTick(1) // 14:20: recovery
	h.wantSent(2)
	h.lastHeader("🔁")
	h.lastContains("🔁 Server arcade di nuovo OK alle 14:20", "primo controllo fallito alle 14:00", "~20 min")

	h.mustTick(2)
	h.wantSent(2)
}

func TestBlipBelowThresholdIsSilent(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.set("arcade", "NotOk", "restart del backend")
	h.mustTick(1)
	h.set("arcade", "Ok", "")
	h.mustTick(3)
	h.wantSent(0)

	st, err := loadState(h.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Servers) != 0 {
		t.Errorf("dopo il rientro lo stato deve essere pulito: %+v", st.Servers)
	}
}

func TestUnknownStateCountsAsFailure(t *testing.T) {
	h := newHarness(t, fakeServer{"arcade", "ok", ""})
	h.mustTick(2)
	h.wantSent(1)
	h.lastContains("Server arcade NON risponde", "stato ok")
}

func TestDisabledIsIgnored(t *testing.T) {
	h := newHarness(t, fakeServer{"the-grid", "Ok", ""}, fakeServer{"arcade", "Disabled", ""})
	h.expect = []string{"the-grid", "arcade"}
	h.mustTick(3)
	h.wantSent(0)
}

func TestAlertedThenDisabledClosesTheLoop(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.set("arcade", "NotOk", "")
	h.mustTick(2)
	h.wantSent(1)
	h.set("arcade", "Disabled", "")
	h.mustTick(1)
	h.wantSent(2)
	h.lastHeader("ℹ️")
	h.lastContains("ℹ️ Server arcade non piu' controllato")
	h.mustTick(2)
	h.wantSent(2)
}

func TestExpectedServerMissing(t *testing.T) {
	h := newHarness(t, fakeServer{"the-grid", "Ok", ""})
	h.expect = []string{"the-grid", "arcade"}
	h.mustTick(2)
	h.wantSent(1)
	h.lastContains("Server arcade NON risponde", "assente dalla lista di Komodo")
}

func TestAPIDownKeepsServerCountersAndRecovers(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.set("arcade", "NotOk", "")
	h.mustTick(1) // arcade: 1 failure

	h.komodo.down = true
	h.mustTick(1) // API: 1 failure, no alert. An API that is down is not an error of the tool
	h.wantSent(0)
	h.mustTick(1)
	h.wantSent(1)
	h.lastContains("🔴 API di Komodo NON risponde", "irraggiungibile dal scope", "HTTP 500", "database down")

	h.komodo.down = false
	h.mustTick(1) // API recovered. arcade gets 2 in a row and does not start from zero
	h.wantSent(2)
	h.lastHeader("🔴") // recovery and failure in the same run: the failure wins
	h.lastContains("🔁 API di Komodo di nuovo OK", "🔴 Server arcade NON risponde", "alle 14:00")
}

func TestAPIUnreachable(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.srv.Close()
	h.mustTick(2)
	h.wantSent(1)
	h.lastContains("🔴 API di Komodo NON risponde")
}

func TestTelegramFailureRetriesNextRun(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.set("arcade", "NotOk", "")
	h.mustTick(1)

	h.notify.fail = errors.New("telegram giu'")
	if err := h.tick(); err == nil {
		t.Fatal("con Telegram giu' il giro deve fallire (exit 1)")
	}
	h.wantSent(0)

	h.notify.fail = nil
	h.mustTick(1) // the change was not lost
	h.wantSent(1)
	h.lastContains("Server arcade NON risponde")
}

func TestUnusedFieldsNeverLeak(t *testing.T) {
	h := newHarness(t, twoServers()...)
	h.set("arcade", "NotOk", "Periphery disconnected")
	h.mustTick(2)
	h.set("arcade", "Ok", "")
	h.mustTick(1)
	h.wantSent(2)

	state, err := os.ReadFile(h.statePath)
	if err != nil {
		t.Fatal(err)
	}
	for where, text := range map[string]string{
		"messaggi": strings.Join(h.notify.sent, "\n"),
		"log":      h.log.String(),
		"stato":    string(state),
	} {
		if strings.Contains(text, leakCanary) {
			t.Errorf("campo non usato finito nei %s", where)
		}
	}
}

func TestTelegramErrorHidesToken(t *testing.T) {
	n := &telegramNotifier{
		botToken: "123:TOKEN-SEGRETO",
		chatID:   "1",
		http:     &http.Client{Timeout: 2 * time.Second},
		baseURL:  "http://127.0.0.1:1", // nessuno in ascolto
	}
	err := n.Send(context.Background(), "prova")
	if err == nil {
		t.Fatal("atteso un errore di connessione")
	}
	if strings.Contains(err.Error(), "TOKEN-SEGRETO") {
		t.Errorf("il token e' finito nell'errore: %v", err)
	}
}

func TestReadSecretTrimsAndRejectsEmpty(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "ok"), []byte("valore\r\n"), 0o400)
	os.WriteFile(filepath.Join(dir, "vuoto"), []byte("\n"), 0o400)

	if v, err := readSecret(dir, "ok"); err != nil || v != "valore" {
		t.Errorf("readSecret(ok) = %q, %v", v, err)
	}
	if _, err := readSecret(dir, "vuoto"); err == nil {
		t.Error("un secret vuoto deve essere un errore")
	}
}

func TestParseExpect(t *testing.T) {
	got := parseExpect(" the-grid, arcade ,,")
	if strings.Join(got, "|") != "the-grid|arcade" {
		t.Errorf("parseExpect = %q", got)
	}
}

func TestRoughDuration(t *testing.T) {
	cases := map[time.Duration]string{
		20 * time.Second:              "meno di 1 min",
		17 * time.Minute:              "~17 min",
		65 * time.Minute:              "~1 h 05 min",
		17*time.Hour + 30*time.Minute: "~17 h 30 min",
	}
	for d, want := range cases {
		if got := roughDuration(d); got != want {
			t.Errorf("roughDuration(%v) = %q, atteso %q", d, got, want)
		}
	}
}
