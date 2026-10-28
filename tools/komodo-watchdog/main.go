// komodo-watchdog: it asks Komodo for the state of the Servers. It sends a Telegram
// message when a Server, or the API, does not answer for more than one check in a row.
// It also sends one when it answers again. It runs on the scope to monitor the-grid and ARCADE from outside.
// Plan: PIANO-KOMODO-SECRETS-GATE.md, Phase 2b. Use and installation: README.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// readSecret reads a secret file. It never prints the contents, also not in errors.
func readSecret(dir, name string) (string, error) {
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return "", fmt.Errorf("secret %s: %w", name, err)
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "", fmt.Errorf("secret %s vuoto", name)
	}
	return value, nil
}

func parseExpect(s string) []string {
	var names []string
	for _, part := range strings.Split(s, ",") {
		if name := strings.TrimSpace(part); name != "" {
			names = append(names, name)
		}
	}
	return names
}

func main() {
	defaultState := ""
	if dir := os.Getenv("STATE_DIRECTORY"); dir != "" { // StateDirectory= of systemd
		defaultState = filepath.Join(dir, "state.json")
	}

	komodoURL := flag.String("komodo-url", "https://komodo.homelab.example", "indirizzo di Komodo Core")
	credDir := flag.String("credentials-dir", os.Getenv("CREDENTIALS_DIRECTORY"), "cartella dei segreti (default: $CREDENTIALS_DIRECTORY di LoadCredential=)")
	statePath := flag.String("state", defaultState, "file di stato (default: $STATE_DIRECTORY/state.json)")
	expect := flag.String("expect", "", "Server che devono comparire, separati da virgola (es. the-grid,arcade)")
	threshold := flag.Int("threshold", 2, "controlli falliti di fila prima dell'avviso")
	hostLabel := flag.String("host-label", "scope", "nome dell'host nei messaggi")
	dryRun := flag.Bool("dry-run", os.Getenv("DRY_RUN") == "1", "stampa il messaggio invece di mandarlo (anche DRY_RUN=1)")
	flag.Parse()

	if err := mainErr(*komodoURL, *credDir, *statePath, parseExpect(*expect), *threshold, *hostLabel, *dryRun); err != nil {
		fmt.Fprintln(os.Stderr, "komodo-watchdog:", err)
		os.Exit(1)
	}
}

func mainErr(komodoURL, credDir, statePath string, expect []string, threshold int, hostLabel string, dryRun bool) error {
	if statePath == "" {
		return errors.New("manca -state (o STATE_DIRECTORY)")
	}
	if credDir == "" {
		return errors.New("manca -credentials-dir (o CREDENTIALS_DIRECTORY)")
	}
	if threshold < 1 {
		return errors.New("-threshold deve essere almeno 1")
	}
	apiKey, err := readSecret(credDir, "komodo_api_key")
	if err != nil {
		return err
	}
	apiSecret, err := readSecret(credDir, "komodo_api_secret")
	if err != nil {
		return err
	}

	httpClient := &http.Client{Timeout: 20 * time.Second}
	var notify notifier = printNotifier{out: os.Stdout}
	if !dryRun {
		botToken, err := readSecret(credDir, "telegram_bot_token")
		if err != nil {
			return err
		}
		chatID, err := readSecret(credDir, "telegram_chat_id")
		if err != nil {
			return err
		}
		notify = &telegramNotifier{botToken: botToken, chatID: chatID, http: httpClient, baseURL: "https://api.telegram.org"}
	}

	w := &watcher{
		api:       &komodoClient{baseURL: strings.TrimRight(komodoURL, "/"), apiKey: apiKey, apiSecret: apiSecret, http: httpClient},
		notify:    notify,
		statePath: statePath,
		hostLabel: hostLabel,
		expect:    expect,
		threshold: threshold,
		now:       time.Now,
		log:       os.Stdout,
		dryRun:    dryRun,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	return w.run(ctx)
}
