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
)

// This value is in the fields that the gate must NOT read (resolved compose config).
// No test must find it in messages, logs or state.
const leakCanary = "SEGRETO-CHE-NON-DEVE-USCIRE"

func digest(ch string) string { return "sha256:" + strings.Repeat(ch, 64) }

type fakeService struct {
	name, image     string
	update          bool
	latest, current string // references as Komodo returns them
}

type fakeKomodo struct {
	stacks map[string][]fakeService
	down   bool
}

func (f *fakeKomodo) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/read" || r.Header.Get("x-api-key") != "k" || r.Header.Get("x-api-secret") != "s" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if f.down {
			http.Error(w, `{"error":"database down"}`, http.StatusInternalServerError)
			return
		}
		var req struct {
			Type   string `json:"type"`
			Params struct {
				Stack string `json:"stack"`
			} `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("richiesta non JSON: %v", err)
		}
		var resp any
		switch req.Type {
		case "ListStacks":
			var list []any
			for name, svcs := range f.stacks {
				var services []any
				for _, s := range svcs {
					services = append(services, map[string]any{
						"service": s.name, "image": s.image, "update_available": s.update, "latest_image": nil,
					})
				}
				list = append(list, map[string]any{"id": "id-" + name, "name": name, "info": map[string]any{"state": "running", "services": services}})
			}
			resp = list
		case "GetStack":
			var latest []any
			for _, s := range f.stacks[req.Params.Stack] {
				latest = append(latest, map[string]any{"service_name": s.name, "image": s.image, "image_digest": s.latest})
			}
			resp = map[string]any{
				"name":   req.Params.Stack,
				"config": map[string]any{"environment": "PASSWORD=" + leakCanary},
				"info": map[string]any{
					"latest_services":   latest,
					"deployed_config":   "environment:\n  - PASSWORD=" + leakCanary,
					"deployed_contents": []any{map[string]any{"contents": leakCanary}},
				},
			}
		case "ListStackServices":
			var list []any
			for _, s := range f.stacks[req.Params.Stack] {
				list = append(list, map[string]any{"service": s.name, "image": s.image, "image_digests": []string{s.current}})
			}
			resp = list
		default:
			http.Error(w, `{"error":"unexpected"}`, http.StatusBadRequest)
			return
		}
		json.NewEncoder(w).Encode(resp)
	}
}

type fakeScanner struct {
	results   map[string]scanResult
	errs      map[string]error
	dbErr     error
	dbUpdates int
	scans     []string
}

func (f *fakeScanner) UpdateDB(context.Context) error { f.dbUpdates++; return f.dbErr }

func (f *fakeScanner) Scan(_ context.Context, ref string) (scanResult, error) {
	f.scans = append(f.scans, ref)
	if err, ok := f.errs[ref]; ok {
		return scanResult{}, err
	}
	if r, ok := f.results[ref]; ok {
		return r, nil
	}
	return scanResult{}, errors.New("immagine sconosciuta al finto scanner: " + ref)
}

func vulns(total int, serious ...string) scanResult {
	r := scanResult{Total: total, BySeverity: map[string]int{"MEDIUM": total - len(serious)}, Serious: map[string]bool{}}
	for _, id := range serious {
		r.BySeverity["HIGH"]++
		r.Serious[id] = true
	}
	return r
}

type recordNotifier struct {
	sent []string
	err  error
}

func (r *recordNotifier) Send(_ context.Context, text string) error {
	if r.err != nil {
		return r.err
	}
	r.sent = append(r.sent, text)
	return nil
}

type harness struct {
	komodo  *fakeKomodo
	scanner *fakeScanner
	notify  *recordNotifier
	gate    *gate
	logs    *bytes.Buffer
}

func newHarness(t *testing.T, k *fakeKomodo, s *fakeScanner) *harness {
	t.Helper()
	srv := httptest.NewServer(k.handler(t))
	t.Cleanup(srv.Close)
	logs := &bytes.Buffer{}
	n := &recordNotifier{}
	return &harness{
		komodo: k, scanner: s, notify: n, logs: logs,
		gate: &gate{
			api:       &komodoClient{baseURL: srv.URL, apiKey: "k", apiSecret: "s", http: srv.Client()},
			scan:      s,
			notify:    n,
			statePath: filepath.Join(t.TempDir(), "state.json"),
			hostLabel: "TEST",
			log:       logs,
		},
	}
}

// The full case: pass, block, scanner error, registry not reachable.
func paperlessScenario() (*fakeKomodo, *fakeScanner) {
	k := &fakeKomodo{stacks: map[string][]fakeService{
		"paperless": {
			{name: "db", image: "postgres:16", update: true,
				latest: "docker.io/library/postgres:16@" + digest("a"), current: "postgres@" + digest("1")},
			{name: "broker", image: "redis:7", update: true,
				latest: "docker.io/library/redis:7@" + digest("b"), current: "redis@" + digest("2")},
			{name: "gotenberg", image: "gotenberg/gotenberg:8", update: true,
				latest: "docker.io/gotenberg/gotenberg:8@" + digest("c"), current: "gotenberg/gotenberg@" + digest("3")},
			{name: "tika", image: "apache/tika:4.0.0", update: false,
				latest: "docker.io/apache/tika:4.0.0@" + digest("d"), current: "apache/tika@" + digest("d")},
		},
		"beszel-agent": {
			{name: "beszel-agent", image: "henrygd/beszel-agent:latest", update: true,
				latest: "henrygd/beszel-agent:latest@" + digest("e"), current: "henrygd/beszel-agent@" + digest("5")},
		},
	}}
	s := &fakeScanner{
		results: map[string]scanResult{
			"docker.io/library/postgres@" + digest("1"):     vulns(40, "CVE-OLD"),
			"docker.io/library/postgres@" + digest("a"):     vulns(35, "CVE-OLD"),
			"docker.io/library/redis@" + digest("2"):        vulns(3),
			"docker.io/library/redis@" + digest("b"):        vulns(5, "CVE-2026-0001", "CVE-2026-0002"),
			"docker.io/gotenberg/gotenberg@" + digest("3"):  vulns(10),
			"docker.io/henrygd/beszel-agent@" + digest("e"): vulns(0),
		},
		errs: map[string]error{
			"docker.io/gotenberg/gotenberg@" + digest("c"):  errors.New("GET https://registry-1.docker.io: dial tcp: i/o timeout"),
			"docker.io/henrygd/beszel-agent@" + digest("5"): errors.New("exit status 1: fatal error: scan failed"),
		},
	}
	return k, s
}

func TestFullRun(t *testing.T) {
	k, s := paperlessScenario()
	h := newHarness(t, k, s)

	if err := h.gate.run(context.Background()); err != nil {
		t.Fatalf("run: %v", err)
	}
	if len(h.notify.sent) != 1 {
		t.Fatalf("attesi 1 messaggio, arrivati %d", len(h.notify.sent))
	}
	msg := h.notify.sent[0]
	for _, want := range []string{
		"✅ paperless/db (postgres:16)",
		"Vulnerabilità: 40 → 35 (meglio)",
		"⛔ paperless/broker (redis:7)",
		"Vulnerabilità: 3 → 5 (peggio)",
		"Gravi (Critical+High): 0 → 2",
		"⚠️ 2 gravi nuove: CVE-2026-0001, CVE-2026-0002",
		"❌ paperless/gotenberg",
		"scansione della candidata: GET https://registry-1.docker.io: dial tcp: i/o timeout",
		"❌ beszel-agent/beszel-agent",
		"Nessun deploy fatto. Quando vuoi:",
		"scansione dell'immagine attuale",
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("manca %q nel messaggio:\n%s", want, msg)
		}
	}
	if strings.Contains(msg, "tika") {
		t.Errorf("tika non ha update, non doveva comparire:\n%s", msg)
	}
	if strings.Contains(msg, "CVE-OLD") {
		t.Errorf("CVE-OLD c'e' anche nell'attuale, non e' nuova:\n%s", msg)
	}
	if s.dbUpdates != 1 {
		t.Errorf("DB aggiornato %d volte, atteso 1 per giro", s.dbUpdates)
	}
	assertNoLeak(t, h)
}

func TestSecondRunIsSilent(t *testing.T) {
	k, s := paperlessScenario()
	h := newHarness(t, k, s)
	for i := 0; i < 2; i++ {
		if err := h.gate.run(context.Background()); err != nil {
			t.Fatalf("giro %d: %v", i+1, err)
		}
	}
	if len(h.notify.sent) != 1 {
		t.Fatalf("il secondo giro identico doveva stare zitto: %d messaggi", len(h.notify.sent))
	}
}

func TestNewCandidateAndApplied(t *testing.T) {
	k, s := paperlessScenario()
	h := newHarness(t, k, s)
	if err := h.gate.run(context.Background()); err != nil {
		t.Fatal(err)
	}

	// The operator deploys db (no more update), and broker gets a new candidate.
	k.stacks["paperless"][0].update = false
	k.stacks["paperless"][1].latest = "docker.io/library/redis:7@" + digest("f")
	s.results["docker.io/library/redis@"+digest("f")] = vulns(2)

	if err := h.gate.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(h.notify.sent) != 2 {
		t.Fatalf("attesi 2 messaggi, arrivati %d", len(h.notify.sent))
	}
	msg := h.notify.sent[1]
	for _, want := range []string{"✅ paperless/broker", "Rientrato: paperless/db"} {
		if !strings.Contains(msg, want) {
			t.Errorf("manca %q:\n%s", want, msg)
		}
	}
	if strings.Contains(msg, "gotenberg") {
		t.Errorf("gotenberg invariato (stesso errore), non doveva ripetersi:\n%s", msg)
	}
}

func TestKomodoDownOnceThenRecovers(t *testing.T) {
	k, s := paperlessScenario()
	h := newHarness(t, k, s)
	if err := h.gate.run(context.Background()); err != nil {
		t.Fatal(err)
	}

	k.down = true
	for i := 0; i < 2; i++ {
		if err := h.gate.run(context.Background()); err == nil {
			t.Fatal("con Komodo giu' il giro deve fallire (unit systemd in failed)")
		}
	}
	if len(h.notify.sent) != 2 || !strings.Contains(h.notify.sent[1], "ERRORE gate (API Komodo)") {
		t.Fatalf("atteso un solo avviso di errore globale, messaggi: %q", h.notify.sent)
	}

	k.down = false
	if err := h.gate.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(h.notify.sent) != 3 || !strings.Contains(h.notify.sent[2], "Rientrato: API Komodo") {
		t.Fatalf("atteso il rientro, messaggi: %q", h.notify.sent)
	}
	if strings.Contains(h.notify.sent[2], "✅ paperless/db") {
		t.Errorf("gli esiti non sono cambiati durante il guasto, non vanno ripetuti:\n%s", h.notify.sent[2])
	}
}

func TestTrivyDBFailure(t *testing.T) {
	k, s := paperlessScenario()
	s.dbErr = errors.New("mirror.gcr.io irraggiungibile")
	h := newHarness(t, k, s)
	if err := h.gate.run(context.Background()); err == nil {
		t.Fatal("atteso errore")
	}
	if len(s.scans) != 0 {
		t.Errorf("senza DB aggiornato non si scansiona: %v", s.scans)
	}
	if len(h.notify.sent) != 1 || !strings.Contains(h.notify.sent[0], "ERRORE gate (DB di Trivy)") {
		t.Fatalf("messaggi: %q", h.notify.sent)
	}
}

func TestTelegramFailureRetriesNextRun(t *testing.T) {
	k, s := paperlessScenario()
	h := newHarness(t, k, s)
	h.notify.err = errors.New("telegram giu'")
	if err := h.gate.run(context.Background()); err == nil {
		t.Fatal("atteso errore di invio")
	}
	if _, err := os.Stat(h.gate.statePath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stato salvato nonostante l'invio fallito: %v", err)
	}
	h.notify.err = nil
	if err := h.gate.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(h.notify.sent) != 1 || !strings.Contains(h.notify.sent[0], "✅ paperless/db") {
		t.Fatalf("l'avviso perso doveva arrivare al giro dopo: %q", h.notify.sent)
	}
}

func TestNoUpdatesNoTrivy(t *testing.T) {
	k := &fakeKomodo{stacks: map[string][]fakeService{
		"flaresolverr": {{name: "flaresolverr", image: "ghcr.io/flaresolverr/flaresolverr:latest",
			latest: "ghcr.io/flaresolverr/flaresolverr:latest@" + digest("a"), current: "ghcr.io/flaresolverr/flaresolverr@" + digest("a")}},
	}}
	s := &fakeScanner{}
	h := newHarness(t, k, s)
	if err := h.gate.run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s.dbUpdates != 0 || len(s.scans) != 0 {
		t.Errorf("nessun update: Trivy non doveva partire (db=%d scans=%v)", s.dbUpdates, s.scans)
	}
	if len(h.notify.sent) != 0 {
		t.Errorf("nessun update, nessun messaggio: %q", h.notify.sent)
	}
}

func TestMissingCandidateDigest(t *testing.T) {
	k := &fakeKomodo{stacks: map[string][]fakeService{
		"seerr": {{name: "seerr", image: "ghcr.io/seerr-team/seerr:latest", update: true,
			latest: "", current: "ghcr.io/seerr-team/seerr@" + digest("1")}},
	}}
	s := &fakeScanner{}
	h := newHarness(t, k, s)
	h.gate.run(context.Background())
	if len(h.notify.sent) != 1 || !strings.Contains(h.notify.sent[0], "❌ seerr/seerr") {
		t.Fatalf("messaggi: %q", h.notify.sent)
	}
	if s.dbUpdates != 0 {
		t.Error("nessuna immagine scansionabile: il DB non andava aggiornato")
	}
}

func assertNoLeak(t *testing.T, h *harness) {
	t.Helper()
	state, _ := os.ReadFile(h.gate.statePath)
	for name, text := range map[string]string{
		"messaggi": strings.Join(h.notify.sent, "\n"),
		"log":      h.logs.String(),
		"stato":    string(state),
	} {
		if strings.Contains(text, leakCanary) {
			t.Errorf("la config di GetStack e' finita in %s", name)
		}
	}
}

func TestSplitDigestRef(t *testing.T) {
	d := digest("a")
	cases := map[string]string{
		"redis:7@" + d:                                   "docker.io/library/redis@" + d,
		"redis@" + d:                                     "docker.io/library/redis@" + d,
		"docker.io/library/redis:7@" + d:                 "docker.io/library/redis@" + d,
		"henrygd/beszel-agent:latest@" + d:               "docker.io/henrygd/beszel-agent@" + d,
		"ghcr.io/fuzzygrim/yamtrack@" + d:                "ghcr.io/fuzzygrim/yamtrack@" + d,
		"ghcr.io/paperless-ngx/paperless-ngx:3.1.1@" + d: "ghcr.io/paperless-ngx/paperless-ngx@" + d,
		"localhost:5000/app:1@" + d:                      "localhost:5000/app@" + d,
	}
	for in, want := range cases {
		repo, dg, err := splitDigestRef(in)
		if err != nil || repo+"@"+dg != want {
			t.Errorf("splitDigestRef(%q) = %q, %v; atteso %q", in, repo+"@"+dg, err, want)
		}
	}
	for _, bad := range []string{"redis:7", "redis@sha256:corto", "redis@md5:" + strings.Repeat("a", 64)} {
		if _, _, err := splitDigestRef(bad); err == nil {
			t.Errorf("splitDigestRef(%q) doveva fallire", bad)
		}
	}
}

func TestParseTrivyJSON(t *testing.T) {
	report := `{"SchemaVersion":2,"Metadata":{"OS":{"Family":"debian","Name":"13.1"}},"Results":[
		{"Target":"x (debian 13)","Vulnerabilities":[
			{"VulnerabilityID":"CVE-1","PkgName":"libssl3","Severity":"CRITICAL"},
			{"VulnerabilityID":"CVE-1","PkgName":"libcrypto3","Severity":"CRITICAL"},
			{"VulnerabilityID":"CVE-2","PkgName":"zlib","Severity":"LOW"}]},
		{"Target":"app/requirements.txt"}]}`
	r, err := parseTrivyJSON([]byte(report))
	if err != nil {
		t.Fatal(err)
	}
	if r.OS != "debian 13.1" || r.Total != 3 || r.BySeverity["CRITICAL"] != 2 || !r.Serious["CVE-1"] || r.Serious["CVE-2"] {
		t.Errorf("conteggio sbagliato: %+v", r)
	}
	if _, err := parseTrivyJSON([]byte("FATAL error")); err == nil {
		t.Error("un output non JSON deve essere un errore, non zero vulnerabilita'")
	}
}

func TestJudgeBoundary(t *testing.T) {
	if v, _ := judge(vulns(10), vulns(10)); v != verdictPass {
		t.Errorf("stesso totale: atteso PASSA (\"More than current\"), avuto %s", v)
	}
	if v, _ := judge(vulns(10), vulns(11)); v != verdictBlock {
		t.Errorf("una in piu': atteso BLOCCA, avuto %s", v)
	}
}

// Candidate with 0 vulnerabilities because Trivy did not identify the OS:
// it must not pass.
func TestJudgeOSNotDetected(t *testing.T) {
	cur, cand := vulns(26), vulns(0)
	cur.OS = "alpine 3.23.5"
	v, detail := judge(cur, cand)
	if v != verdictError || !strings.Contains(detail, "non confrontabile") {
		t.Errorf("atteso ERRORE, avuto %s: %s", v, detail)
	}

	// Image with only the binary (beszel-agent): no OS in the two images, so compare.
	if v, _ := judge(vulns(3), vulns(1)); v != verdictPass {
		t.Errorf("senza sistema da entrambe le parti: atteso PASSA, avuto %s", v)
	}

	// OS change (for example debian -> alpine): compare, and the message tells it.
	cand.OS = "alpine 3.24.0"
	cand.Total = 20
	if v, detail := judge(cur, cand); v != verdictPass || !strings.Contains(detail, "Sistema: alpine 3.23.5 -> alpine 3.24.0") {
		t.Errorf("atteso PASSA con cambio di sistema nel dettaglio, avuto %s: %s", v, detail)
	}
}

func TestTelegramErrorHidesToken(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close() // connection refused
	n := &telegramNotifier{botToken: "123456:TOKEN-SEGRETO", chatID: "1", http: http.DefaultClient, baseURL: url}
	err := n.Send(context.Background(), "ciao")
	if err == nil {
		t.Fatal("atteso errore")
	}
	if strings.Contains(err.Error(), "TOKEN-SEGRETO") {
		t.Errorf("il token e' finito nell'errore: %v", err)
	}
}
