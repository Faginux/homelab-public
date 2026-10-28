package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// State between two runs: it lets the tool send a Telegram message only when
// something changes, as docker-compose-drift-check does.
type savedOutcome struct {
	Candidate string `json:"candidate"`
	Verdict   string `json:"verdict"`
}

type gateState struct {
	// Error that stopped the full run (Komodo API, Trivy database). "" if none.
	GlobalError string                  `json:"global_error,omitempty"`
	Services    map[string]savedOutcome `json:"services"`
}

func loadState(path string) (gateState, error) {
	st := gateState{Services: map[string]savedOutcome{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil // first run
	}
	if err != nil {
		return st, fmt.Errorf("lettura stato: %w", err)
	}
	if err := json.Unmarshal(data, &st); err != nil {
		return st, fmt.Errorf("stato %s non leggibile: %w", path, err)
	}
	if st.Services == nil {
		st.Services = map[string]savedOutcome{}
	}
	return st, nil
}

// saveState writes a temporary file and renames it: an interrupted run does not
// leave a half-written state.
func saveState(path string, st gateState) error {
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*.json")
	if err != nil {
		return fmt.Errorf("scrittura stato: %w", err)
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("scrittura stato: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("scrittura stato: %w", err)
	}
	return os.Rename(tmp.Name(), path)
}

// globalFailure is an error that stops the full run. Kind is stable ("API Komodo",
// "DB di Trivy") and goes into the state. Detail changes between runs (error
// text) and goes only into the message. If not, each run would look "new".
type globalFailure struct {
	Kind   string
	Detail string
}

// nextState compares this run with the previous run. It returns the new state and
// the lines to send (empty = no message).
func nextState(prev gateState, outcomes []outcome, failure *globalFailure) (gateState, []string) {
	var lines []string

	if failure != nil {
		// The run gave no results: keep the old results, and report only
		// the error, and only if it is new.
		next := gateState{GlobalError: failure.Kind, Services: prev.Services}
		if failure.Kind != prev.GlobalError {
			lines = append(lines, fmt.Sprintf("ERRORE gate (%s): %s", failure.Kind, failure.Detail))
		}
		return next, lines
	}

	next := gateState{Services: map[string]savedOutcome{}}
	if prev.GlobalError != "" {
		lines = append(lines, "Rientrato: "+prev.GlobalError+" di nuovo a posto, il gate gira")
	}

	sorted := append([]outcome(nil), outcomes...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].key() < sorted[j].key() })
	for _, o := range sorted {
		next.Services[o.key()] = savedOutcome{Candidate: o.Candidate, Verdict: o.Verdict}
		old, seen := prev.Services[o.key()]
		if seen && old.Candidate == o.Candidate && old.Verdict == o.Verdict {
			continue
		}
		lines = append(lines, outcomeLine(o))
	}

	var gone []string
	for key := range prev.Services {
		if _, still := next.Services[key]; !still {
			gone = append(gone, key)
		}
	}
	sort.Strings(gone)
	for _, key := range gone {
		lines = append(lines, "Rientrato: "+key+" (update applicato o candidata sparita)")
	}
	return next, lines
}

func buildMessage(hostLabel string, lines []string) string {
	const telegramMax = 4000 // limit 4096, with a margin
	body := strings.Join(lines, "\n")
	var legend []string
	if strings.Contains(body, "✅ ") {
		legend = append(legend, "✅ = la nuova versione non ha più vulnerabilità di quella attuale.")
	}
	if strings.Contains(body, "⛔ ") {
		legend = append(legend, "⛔ = la nuova versione ne ha di più: meglio aspettare.")
	}
	if strings.Contains(body, "❌ ") {
		legend = append(legend, "❌ = controllo non riuscito: non è un via libera.")
	}
	footer := "Nessun deploy fatto."
	if strings.Contains(body, "✅ ") {
		footer += " Quando vuoi: prima `docker compose --dry-run up -d`, poi Deploy in Komodo."
	}
	legend = append(legend, footer)
	msg := "ℹ️ 🖧 " + hostLabel + " · 🛡️ Gate CVE\n\n" + body + "\n\n" + strings.Join(legend, "\n")
	if len(msg) > telegramMax {
		msg = msg[:telegramMax] + "\n[...troncato, dettagli nel journal]"
	}
	return msg
}
