package main

import (
	"context"
	"fmt"
	"io"
	"maps"
	"slices"
	"strings"
	"time"
)

const (
	stateOk       = "Ok"
	stateDisabled = "Disabled"
)

// Status emoji of the uniform format of the "Ops" bot (CENSIMENTO-BOT-TELEGRAM.md),
// from the most serious: the header uses the most serious emoji of the lines.
const (
	iconDown      = "🔴"
	iconRecovered = "🔁"
	iconInfo      = "ℹ️"
)

type check struct {
	failing bool
	detail  string // cause of the failure: only in the message, never in the state
}

// notice is one line of the message. Empty text = nothing to say.
type notice struct {
	icon string
	text string
}

type watcher struct {
	api       komodoAPI
	notify    notifier
	statePath string
	hostLabel string
	expect    []string
	threshold int
	now       func() time.Time
	log       io.Writer
	dryRun    bool
}

func (w *watcher) run(ctx context.Context) error {
	prev, err := loadState(w.statePath)
	if err != nil {
		return err
	}
	now := w.now()

	var checks map[string]check // nil = the API did not answer, the state of the Servers is unknown
	servers, apiErr := w.api.ListServers(ctx)
	if apiErr != nil {
		fmt.Fprintf(w.log, "API di Komodo: ERRORE: %v\n", apiErr)
	} else {
		for _, s := range servers {
			fmt.Fprintf(w.log, "%s: %s\n", s.Name, s.Info.State)
		}
		checks = classify(servers, w.expect)
	}

	next, notices := nextState(prev, apiErr, checks, now, w.threshold)
	if len(notices) == 0 {
		fmt.Fprintln(w.log, "niente di nuovo: nessun messaggio")
	} else {
		// Save the state only after a successful send. If Telegram fails, the change
		// comes back at the next run and is not lost.
		if err := w.notify.Send(ctx, buildMessage(w.hostLabel, notices)); err != nil {
			return err
		}
		if w.dryRun {
			fmt.Fprintf(w.log, "DRY_RUN: messaggio di %d righe stampato, non inviato\n", len(notices))
		} else {
			fmt.Fprintf(w.log, "messaggio Telegram inviato (%d righe)\n", len(notices))
		}
	}
	// An API that is down is not a failure of the watchdog: it is the thing that the
	// watchdog monitors. It reports it on Telegram and exits 0. It exits 1 only if it cannot do its work.
	return saveState(w.statePath, next)
}

func classify(servers []serverListItem, expect []string) map[string]check {
	checks := map[string]check{}
	listed := map[string]bool{}
	for _, s := range servers {
		listed[s.Name] = true
		switch s.Info.State {
		case stateDisabled:
			// Disabled in Komodo on purpose: no check.
		case stateOk:
			checks[s.Name] = check{}
		default:
			// NotOk, and also a value never seen before: a false alarm is better than a
			// silent failure if the API changes.
			state := s.Info.State
			if state == "" {
				state = "(vuoto)"
			}
			detail := "stato " + state
			if s.Info.Err != nil && s.Info.Err.Error != "" {
				detail += ": " + oneLine(s.Info.Err.Error, 200)
			}
			checks[s.Name] = check{failing: true, detail: detail}
		}
	}
	// An empty or incomplete list (permission removed, Server renamed) must not look
	// like "all is correct".
	for _, name := range expect {
		if !listed[name] {
			checks[name] = check{failing: true, detail: "assente dalla lista di Komodo (permesso Read tolto o Server rinominato?)"}
		}
	}
	return checks
}

// nextState compares this run with the previous run. It returns the new state and the
// lines to send (none = no message).
func nextState(prev watchState, apiErr error, checks map[string]check, now time.Time, threshold int) (watchState, []notice) {
	next := watchState{Servers: map[string]targetState{}}
	var notices []notice
	add := func(n notice) {
		if n.text != "" {
			notices = append(notices, n)
		}
	}

	apiCheck := check{}
	if apiErr != nil {
		apiCheck = check{failing: true, detail: "irraggiungibile dal scope (the-grid, Core o Caddy giu'?): " + oneLine(apiErr.Error(), 200)}
	}
	var n notice
	next.API, n = step(prev.API, apiCheck, "API di Komodo", now, threshold)
	add(n)

	if checks == nil {
		maps.Copy(next.Servers, prev.Servers)
		return next, notices
	}

	for _, name := range slices.Sorted(maps.Keys(checks)) {
		st, n := step(prev.Servers[name], checks[name], "Server "+name, now, threshold)
		if st.Failures > 0 {
			next.Servers[name] = st
		}
		add(n)
	}
	for _, name := range slices.Sorted(maps.Keys(prev.Servers)) {
		if _, still := checks[name]; !still && prev.Servers[name].Alerted {
			add(notice{iconInfo, "Server " + name + " non piu' controllato (disabilitato o rimosso in Komodo): nessun rientro da segnalare"})
		}
	}
	return next, notices
}

// step updates a target with the result of the check. It returns the new state and
// the line to send (empty text = no message).
func step(prev targetState, c check, name string, now time.Time, threshold int) (targetState, notice) {
	if !c.failing {
		if prev.Alerted {
			return targetState{}, notice{iconRecovered, fmt.Sprintf("%s di nuovo OK alle %s (primo controllo fallito alle %s, giu' per %s)",
				name, hhmm(now), hhmm(prev.Since), roughDuration(now.Sub(prev.Since)))}
		}
		return targetState{}, notice{} // failure below the threshold: recovered with no message
	}
	next := prev
	if next.Failures == 0 {
		next.Since = now
	}
	next.Failures++
	if next.Failures >= threshold && !next.Alerted {
		next.Alerted = true
		return next, notice{iconDown, fmt.Sprintf("%s NON risponde: primo controllo fallito alle %s, %d di fila\n   %s",
			name, hhmm(next.Since), next.Failures, c.detail)}
	}
	return next, notice{}
}

// buildMessage uses the standard header of the "Ops" bot:
// <status-emoji> <host-emoji> <Host> · <service-emoji> <Service>
func buildMessage(hostLabel string, notices []notice) string {
	const telegramMax = 4000 // limit 4096, with a margin
	lines := make([]string, len(notices))
	for i, n := range notices {
		lines[i] = n.icon + " " + n.text
	}
	msg := headerIcon(notices) + " 🍓 " + hostLabel + " · 🐕 Komodo watchdog\n\n" + strings.Join(lines, "\n")
	if len(msg) > telegramMax {
		msg = msg[:telegramMax] + "\n[...troncato, dettagli nel journal]"
	}
	return msg
}

// headerIcon selects the most serious line: a new failure must not hide behind a
// recovery that came in the same run.
func headerIcon(notices []notice) string {
	for _, icon := range []string{iconDown, iconRecovered} {
		if slices.ContainsFunc(notices, func(n notice) bool { return n.icon == icon }) {
			return icon
		}
	}
	return iconInfo
}

func hhmm(t time.Time) string { return t.Local().Format("15:04") }

func roughDuration(d time.Duration) string {
	m := int(d.Round(time.Minute) / time.Minute)
	switch {
	case m < 1:
		return "meno di 1 min"
	case m < 60:
		return fmt.Sprintf("~%d min", m)
	default:
		return fmt.Sprintf("~%d h %02d min", m/60, m%60)
	}
}

func oneLine(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > max {
		return string(r[:max]) + "..."
	}
	return s
}
