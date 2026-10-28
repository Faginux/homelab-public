// komodo-gate: for each service in Komodo that has a newer image, it scans the
// current image and the candidate with Trivy. It applies "More than current".
// It sends a Telegram message when something changes. It never deploys.
// Plan: PIANO-KOMODO-SECRETS-GATE.md, Phase 3. Use and installation: README.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Tag + digest: if the publisher publishes a tag again, the scanner does not change.
const defaultTrivyImage = "aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969"

type gate struct {
	api       komodoAPI
	scan      scanner
	notify    notifier
	statePath string
	hostLabel string
	log       io.Writer
	dryRun    bool
}

func (g *gate) run(ctx context.Context) error {
	prev, err := loadState(g.statePath)
	if err != nil {
		return err
	}

	var outcomes []outcome
	var failure *globalFailure

	cands, err := findCandidates(ctx, g.api)
	if err != nil {
		failure = &globalFailure{Kind: "API Komodo", Detail: err.Error()}
	} else {
		fmt.Fprintf(g.log, "servizi con update in Komodo: %d\n", len(cands))
		// Trivy starts only if there is minimum one image to scan.
		if needsScan(cands) {
			if err := g.scan.UpdateDB(ctx); err != nil {
				failure = &globalFailure{Kind: "DB di Trivy", Detail: err.Error()}
			}
		}
		if failure == nil {
			outcomes = evaluateAll(ctx, g.scan, cands)
		}
	}

	for _, o := range outcomes {
		fmt.Fprintf(g.log, "%s %s (%s): %s\n", o.Verdict, o.key(), o.Image, o.Detail)
	}
	if failure != nil {
		fmt.Fprintf(g.log, "ERRORE (%s): %s\n", failure.Kind, failure.Detail)
	}

	next, lines := nextState(prev, outcomes, failure)
	if len(lines) > 0 {
		// Save the state only after a successful send. If Telegram fails, the next run
		// tries again and the alert is not lost (as in the drift-check).
		if err := g.notify.Send(ctx, buildMessage(g.hostLabel, lines)); err != nil {
			return err
		}
		if g.dryRun {
			fmt.Fprintf(g.log, "DRY_RUN: messaggio di %d righe stampato, non inviato\n", len(lines))
		} else {
			fmt.Fprintf(g.log, "messaggio Telegram inviato (%d righe)\n", len(lines))
		}
	} else {
		fmt.Fprintln(g.log, "niente di nuovo: nessun messaggio")
	}
	if err := saveState(g.statePath, next); err != nil {
		return err
	}
	if failure != nil {
		return fmt.Errorf("giro fallito: %s", failure.Kind)
	}
	return nil
}

func needsScan(cands []candidate) bool {
	for _, c := range cands {
		if c.Problem == "" {
			return true
		}
	}
	return false
}

// readSecret reads a secret file. It never prints the contents, also not in errors.
func readSecret(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("secret file: %w", err)
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "", fmt.Errorf("secret file %s vuoto", path)
	}
	return value, nil
}

func main() {
	defaultState := ""
	if dir := os.Getenv("STATE_DIRECTORY"); dir != "" { // StateDirectory= of systemd
		defaultState = filepath.Join(dir, "state.json")
	}

	komodoURL := flag.String("komodo-url", "http://127.0.0.1:9120", "indirizzo di Komodo Core")
	secretsDir := flag.String("secrets-dir", "/srv/docker/_secrets", "cartella con komodo-gate/ e telegram/")
	statePath := flag.String("state", defaultState, "file di stato (default: $STATE_DIRECTORY/state.json)")
	trivyImage := flag.String("trivy-image", defaultTrivyImage, "immagine di Trivy")
	cacheVolume := flag.String("trivy-cache-volume", "komodo-gate-trivy-cache", "volume Docker per la cache di Trivy")
	platform := flag.String("platform", "linux/amd64", "piattaforma da scansionare")
	hostLabel := flag.String("host-label", "the-grid", "nome dell'host nei messaggi")
	dryRun := flag.Bool("dry-run", os.Getenv("DRY_RUN") == "1", "stampa il messaggio invece di mandarlo (anche DRY_RUN=1)")
	flag.Parse()

	if err := mainErr(*komodoURL, *secretsDir, *statePath, *trivyImage, *cacheVolume, *platform, *hostLabel, *dryRun); err != nil {
		fmt.Fprintln(os.Stderr, "komodo-gate:", err)
		os.Exit(1)
	}
}

func mainErr(komodoURL, secretsDir, statePath, trivyImage, cacheVolume, platform, hostLabel string, dryRun bool) error {
	if statePath == "" {
		return errors.New("manca -state (o STATE_DIRECTORY)")
	}
	apiKey, err := readSecret(filepath.Join(secretsDir, "komodo-gate", "api_key"))
	if err != nil {
		return err
	}
	apiSecret, err := readSecret(filepath.Join(secretsDir, "komodo-gate", "api_secret"))
	if err != nil {
		return err
	}

	httpClient := &http.Client{Timeout: 30 * time.Second}
	var notify notifier = printNotifier{out: os.Stdout}
	if !dryRun {
		botToken, err := readSecret(filepath.Join(secretsDir, "telegram", "bot_token"))
		if err != nil {
			return err
		}
		chatID, err := readSecret(filepath.Join(secretsDir, "telegram", "chat_id"))
		if err != nil {
			return err
		}
		notify = &telegramNotifier{botToken: botToken, chatID: chatID, http: httpClient, baseURL: "https://api.telegram.org"}
	}

	g := &gate{
		api:       &komodoClient{baseURL: strings.TrimRight(komodoURL, "/"), apiKey: apiKey, apiSecret: apiSecret, http: httpClient},
		scan:      &trivyScanner{image: trivyImage, cacheVolume: cacheVolume, platform: platform},
		notify:    notify,
		statePath: statePath,
		hostLabel: hostLabel,
		log:       os.Stdout,
		dryRun:    dryRun,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Minute)
	defer cancel()
	return g.run(ctx)
}
