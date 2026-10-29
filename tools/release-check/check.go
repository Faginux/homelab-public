package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"strings"
)

type imageConfig struct {
	Track string `json:"track"` // major (default), minor, any, rebuild
	Notes string `json:"notes"` // release notes URL for the message
	Skip  bool   `json:"skip"`
}

type config struct {
	Roots  []root                 `json:"roots"`
	Images map[string]imageConfig `json:"images"` // key = short image name ("mariadb")
}

func loadConfig(path string) (config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return config{}, fmt.Errorf("read config: %w", err)
	}
	var cfg config
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields() // a typo in a key must fail, not be ignored
	if err := dec.Decode(&cfg); err != nil {
		return config{}, fmt.Errorf("config %s: %w", path, err)
	}
	if len(cfg.Roots) == 0 {
		return config{}, fmt.Errorf("config %s: no roots", path)
	}
	for name, ic := range cfg.Images {
		if ic.Track != "" && !validTrack(ic.Track) {
			return config{}, fmt.Errorf("config %s: image %s: unknown track %q", path, name, ic.Track)
		}
	}
	return cfg, nil
}

// target is one distinct image reference, with every place that uses it.
type target struct {
	Ref    imageRef
	Places []string
	Track  string
	Notes  string
}

// buildTargets groups the pins by exact reference and applies the config. The second
// result lists config keys that match no pin (a stale entry is a warning, not an error).
func buildTargets(pins []pin, cfg config) ([]target, []string) {
	byRef := map[string]*target{}
	var order []string
	used := map[string]bool{}
	for _, p := range pins {
		ic, hasCfg := cfg.Images[p.Ref.Name]
		if hasCfg {
			used[p.Ref.Name] = true
			if ic.Skip {
				continue
			}
		}
		key := p.Ref.String()
		t, ok := byRef[key]
		if !ok {
			track := ic.Track
			_, isVersion := parseVersion(p.Ref.Tag)
			if track == "" {
				track = trackMajor
			}
			if !isVersion {
				track = trackRebuild // a floating tag with a digest: only a rebuild can show
			}
			t = &target{Ref: p.Ref, Track: track, Notes: ic.Notes}
			byRef[key] = t
			order = append(order, key)
		}
		if !contains(t.Places, p.Place) {
			t.Places = append(t.Places, p.Place)
		}
	}
	var stale []string
	for name := range cfg.Images {
		if !used[name] {
			stale = append(stale, name)
		}
	}
	sort.Strings(stale)
	out := make([]target, 0, len(order))
	for _, k := range order {
		out = append(out, *byRef[k])
	}
	return out, stale
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// finding is the result for one target.
type finding struct {
	Key       string
	Name      string
	Places    string
	Notes     string
	Pin       string // the tag of the pin
	Safe      string // newest version in the track, "" if none
	Major     string // newest version with a higher first part, "" if none
	NewDigest string // digest of the pinned tag in the registry, only if it differs from the pin
	Err       string
}

func (f finding) empty() bool {
	return f.Safe == "" && f.Major == "" && f.NewDigest == "" && f.Err == ""
}

func evaluate(ctx context.Context, reg registry, t target) finding {
	f := finding{
		Key:    t.Ref.Name + ":" + t.Ref.Tag,
		Name:   t.Ref.Name,
		Places: strings.Join(t.Places, ", "),
		Notes:  t.Notes,
		Pin:    t.Ref.Tag,
	}
	if pinVer, isVersion := parseVersion(t.Ref.Tag); isVersion && t.Track != trackRebuild {
		tags, err := reg.Tags(ctx, t.Ref)
		if err != nil {
			f.Err = "tags: " + err.Error()
			return f
		}
		safe, major := pickCandidates(t.Track, pinVer, tags)
		if safe != nil {
			f.Safe = safe.String()
		}
		if major != nil {
			f.Major = major.String()
		}
	}
	if t.Ref.Digest != "" {
		d, err := reg.Digest(ctx, t.Ref, t.Ref.Tag)
		if err != nil {
			f.Err = "digest: " + err.Error()
			return f
		}
		if d != t.Ref.Digest {
			f.NewDigest = d
		}
	}
	return f
}

// record is what the state file keeps for a finding that needs attention. The error
// text is not part of it: it changes every round and would look like news.
type record struct {
	Safe      string `json:"safe,omitempty"`
	Major     string `json:"major,omitempty"`
	NewDigest string `json:"new_digest,omitempty"`
	Err       bool   `json:"error,omitempty"`
}

type releaseState struct {
	Images map[string]record `json:"images"`
}

func recordOf(f finding) record {
	return record{Safe: f.Safe, Major: f.Major, NewDigest: f.NewDigest, Err: f.Err != ""}
}

func where(f finding) string {
	return f.Name + " (" + f.Places + ")"
}

// report is one item of the message of a round: news about an image (Finding), or a
// plain line (Rientrato, ERRORE).
type report struct {
	Finding *finding
	Line    string
}

// nextState compares this round with the saved one. It returns the new state and the
// reports to send (empty = silence).
func nextState(prev releaseState, findings []finding) (releaseState, []report) {
	next := releaseState{Images: map[string]record{}}
	var lines []report

	sorted := append([]finding(nil), findings...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Key < sorted[j].Key })
	for _, f := range sorted {
		old, seen := prev.Images[f.Key]
		if f.empty() {
			if seen {
				reason := "pin aggiornato"
				if old.Err {
					reason = "registro di nuovo raggiungibile"
				}
				lines = append(lines, report{Line: fmt.Sprintf("Rientrato: %s (%s)", f.Name, reason)})
			}
			continue
		}
		rec := recordOf(f)
		next.Images[f.Key] = rec
		if !seen || old != rec {
			if f.Err != "" {
				lines = append(lines, report{Line: "ERRORE " + f.Name + ": " + f.Err})
			} else {
				news := f // own copy: the report keeps a pointer
				lines = append(lines, report{Finding: &news})
			}
		}
	}

	var gone []string
	for key := range prev.Images {
		if _, still := next.Images[key]; still {
			continue
		}
		if !hasKey(sorted, key) {
			gone = append(gone, key)
		}
	}
	sort.Strings(gone)
	for _, key := range gone {
		lines = append(lines, report{Line: "Rientrato: " + key + " (pin cambiato o immagine tolta dal compose)"})
	}
	return next, lines
}

func hasKey(findings []finding, key string) bool {
	for _, f := range findings {
		if f.Key == key {
			return true
		}
	}
	return false
}

const (
	telegramMax   = 4000 // the limit is 4096, with margin
	maxPartRunes  = 600  // one block or line never gets longer than this
	markerReserve = 100  // room for the "troncato" line
)

// htmlEscape is all that Telegram parse_mode=HTML needs for plain text.
var htmlEscape = strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;")

// clip cuts s to n runes, so it never cuts inside a UTF-8 sequence.
func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// fit joins whole parts while they fit in budget bytes. It returns the text and the
// number of parts left out. A part is never cut: a cut could split an HTML entity or tag,
// and Telegram refuses the whole message then.
func fit(parts []string, sep string, budget int) (string, int) {
	var b strings.Builder
	for i, p := range parts {
		add := len(p)
		if i > 0 {
			add += len(sep)
		}
		if b.Len()+add > budget {
			return b.String(), len(parts) - i
		}
		if i > 0 {
			b.WriteString(sep)
		}
		b.WriteString(p)
	}
	return b.String(), 0
}

// imageBlock is the text for one image: what changed, and where the release notes are.
func imageBlock(f finding) string {
	var b strings.Builder
	b.WriteString("📦 " + f.Name + " — " + f.Places)
	if f.Safe != "" {
		b.WriteString("\n   ⬆️ " + f.Pin + " → " + f.Safe)
	}
	if f.NewDigest != "" {
		b.WriteString("\n   🔁 " + f.Pin + " ricostruita (stesso tag, digest nuovo)")
	}
	if f.Major != "" {
		b.WriteString("\n   🆕 major " + f.Pin + " → " + f.Major + " (da valutare, non nel comando)")
	}
	if f.Notes != "" {
		b.WriteString("\n   🔗 " + f.Notes)
	}
	return b.String()
}

// applyPrompt is the text that Faginux pastes in Claude Code. It stops before the deploy
// (rule number one): Claude edits the pins and shows the diff and the dry run.
// It is already HTML-escaped, for a <pre> block.
func applyPrompt(todo []finding, budget int) string {
	const intro = "Release-check: applica questi aggiornamenti ai pin, uno stack alla volta."
	const outro = "Per ognuno: leggi le note di rilascio, controlla il backup, modifica il pin (tag e digest), " +
		"mostrami il diff e `docker compose --dry-run up -d`. Poi fermati: il deploy lo faccio io, dopo il mio OK."
	items := make([]string, 0, len(todo))
	for _, f := range todo {
		item := "- " + where(f) + ": "
		if f.Safe != "" { // a new version makes a rebuild of the old tag useless
			item += f.Pin + " → " + f.Safe
		} else {
			item += f.Pin + ", stesso tag, digest nuovo"
		}
		if f.Notes != "" {
			item += " (note: " + f.Notes + ")"
		}
		items = append(items, htmlEscape.Replace(clip(item, maxPartRunes)))
	}
	list, omitted := fit(items, "\n", budget-len(intro)-len(outro)-markerReserve)
	if omitted > 0 {
		list += fmt.Sprintf("\n- ... altre %d immagini: vedi sopra", omitted)
	}
	return intro + "\n" + list + "\n" + outro
}

// buildMessage makes the Telegram text (HTML parse mode). A block per image, the plain
// lines, then the prompt to paste. Only the blocks and lines are ever left out.
func buildMessage(hostLabel string, reports []report) string {
	var parts, plain []string
	var todo []finding
	hasMajor := false
	for _, r := range reports {
		if r.Finding == nil {
			plain = append(plain, htmlEscape.Replace(clip(r.Line, maxPartRunes)))
			continue
		}
		f := *r.Finding
		parts = append(parts, htmlEscape.Replace(clip(imageBlock(f), maxPartRunes)))
		if f.Safe != "" || f.NewDigest != "" {
			todo = append(todo, f)
		}
		hasMajor = hasMajor || f.Major != ""
	}
	parts = append(parts, plain...)

	head := "⬆️ 🐧 " + htmlEscape.Replace(hostLabel) + " · 📦 Release immagini pinnate"
	tail := ""
	switch {
	case len(todo) > 0:
		tail = "Per applicare, incolla in Claude Code (cartella homelab):\n<pre>" + applyPrompt(todo, telegramMax/2) + "</pre>"
	case hasMajor:
		tail = "Solo nuove major: nessun comando pronto, vanno valutate prima."
	}

	body, omitted := fit(parts, "\n\n", telegramMax-len(head)-len(tail)-markerReserve)
	msg := head + "\n\n" + body
	if omitted > 0 {
		msg += fmt.Sprintf("\n\n[...troncato: altre %d voci, dettagli nel journal]", omitted)
	}
	if tail != "" {
		msg += "\n\n" + tail
	}
	return msg
}

// scanAndEvaluate is the read-only part of a round.
func scanAndEvaluate(ctx context.Context, repo fs.FS, cfg config, reg registry, logf func(string, ...any)) ([]finding, error) {
	pins, skips, err := scanPins(repo, cfg.Roots)
	if err != nil {
		return nil, err
	}
	for _, s := range skips {
		logf("skip %s: %s", s.Image, s.Reason)
	}
	targets, stale := buildTargets(pins, cfg)
	for _, name := range stale {
		logf("warning: config entry %q matches no pin", name)
	}
	logf("images to check: %d", len(targets))
	var findings []finding
	for _, t := range targets {
		f := evaluate(ctx, reg, t)
		switch {
		case f.Err != "":
			logf("ERROR %s: %s", f.Key, f.Err)
		case f.empty():
			logf("ok %s", f.Key)
		default:
			logf("news %s: safe=%q major=%q rebuilt=%v", f.Key, f.Safe, f.Major, f.NewDigest != "")
		}
		findings = append(findings, f)
	}
	return findings, nil
}
