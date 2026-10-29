// release-check: reads the pinned images in the compose files of the repo, asks the
// registries for newer versions and writes to Telegram when something changes.
// It never pulls and never deploys. Plan: PIANO-RELEASE-CHECK.md. Use and install: README.md.
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

type checker struct {
	repo      string
	cfg       config
	reg       registry
	notify    notifier
	statePath string
	hostLabel string
	log       io.Writer
	dryRun    bool
}

func (c *checker) run(ctx context.Context) error {
	prev, err := loadState(c.statePath)
	if err != nil {
		return err
	}
	logf := func(format string, args ...any) { fmt.Fprintf(c.log, format+"\n", args...) }

	findings, err := scanAndEvaluate(ctx, os.DirFS(c.repo), c.cfg, c.reg, logf)
	if err != nil {
		return err
	}
	next, reports := nextState(prev, findings)

	if len(reports) > 0 {
		// Save the state only after a successful send. If Telegram fails, the next
		// round tries again instead of losing the notice (same rule as komodo-gate).
		if err := c.notify.Send(ctx, buildMessage(c.hostLabel, reports)); err != nil {
			return err
		}
		if !c.dryRun {
			logf("telegram message sent (%d items)", len(reports))
		}
	} else {
		logf("nothing new: no message")
	}
	if c.dryRun {
		logf("DRY_RUN: state not saved")
	} else if err := saveState(c.statePath, next); err != nil {
		return err
	}

	failed := 0
	for _, f := range findings {
		if f.Err != "" {
			failed++
		}
	}
	if failed > 0 {
		return fmt.Errorf("%d image(s) could not be checked", failed)
	}
	return nil
}

// readSecret reads a secret file and never prints it, not even in errors.
func readSecret(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("secret file: %w", err)
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "", fmt.Errorf("secret file %s is empty", path)
	}
	return value, nil
}

func main() {
	defaultState := ""
	if dir := os.Getenv("STATE_DIRECTORY"); dir != "" { // StateDirectory= of systemd
		defaultState = filepath.Join(dir, "state.json")
	}

	repo := flag.String("repo", ".", "root of the homelab clone")
	cfgPath := flag.String("config", "", "config file (default: <repo>/tools/release-check/config.json)")
	secretsDir := flag.String("secrets-dir", "/srv/docker/_secrets", "folder with telegram/")
	statePath := flag.String("state", defaultState, "state file (default: $STATE_DIRECTORY/state.json)")
	hostLabel := flag.String("host-label", "the-grid", "host name in the message")
	dryRun := flag.Bool("dry-run", os.Getenv("DRY_RUN") == "1", "print the message instead of sending it, and do not save the state (also DRY_RUN=1)")
	flag.Parse()

	if *cfgPath == "" {
		*cfgPath = filepath.Join(*repo, "tools", "release-check", "config.json")
	}
	if err := mainErr(*repo, *cfgPath, *secretsDir, *statePath, *hostLabel, *dryRun); err != nil {
		fmt.Fprintln(os.Stderr, "release-check:", err)
		os.Exit(1)
	}
}

func mainErr(repo, cfgPath, secretsDir, statePath, hostLabel string, dryRun bool) error {
	if statePath == "" && !dryRun {
		return errors.New("missing -state (or STATE_DIRECTORY)")
	}
	cfg, err := loadConfig(cfgPath)
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

	c := &checker{
		repo:      repo,
		cfg:       cfg,
		reg:       newHTTPRegistry(httpClient),
		notify:    notify,
		statePath: statePath,
		hostLabel: hostLabel,
		log:       os.Stdout,
		dryRun:    dryRun,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	return c.run(ctx)
}
