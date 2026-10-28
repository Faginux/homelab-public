package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
)

const (
	verdictPass  = "PASSA"
	verdictBlock = "BLOCCA"
	verdictError = "ERRORE"
)

// candidate is a service for which the Komodo poll shows a newer image.
type candidate struct {
	Stack     string
	Service   string
	Image     string // as the compose writes it, only for the message
	Current   string // repo@sha256:... that runs now
	Candidate string // repo@sha256:... from the registry
	Problem   string // if not empty: no scan, result ERROR
}

func (c candidate) key() string { return c.Stack + "/" + c.Service }

type outcome struct {
	Stack     string
	Service   string
	Image     string
	Candidate string
	Verdict   string
	Detail    string
}

func (o outcome) key() string { return o.Stack + "/" + o.Service }

// findCandidates reads from Komodo the services with update_available. For each
// service, it reads the current digest and the candidate digest. An error on one stack
// becomes a candidate with Problem (ERROR in the report) and does not stop the others.
// Only a failure of ListStacks is a global error.
func findCandidates(ctx context.Context, api komodoAPI) ([]candidate, error) {
	stacks, err := api.ListStacks(ctx)
	if err != nil {
		return nil, fmt.Errorf("API Komodo: %w", err)
	}

	var found []candidate
	for _, st := range stacks {
		var wanted []candidate
		for _, sv := range st.Info.Services {
			if sv.UpdateAvailable {
				wanted = append(wanted, candidate{Stack: st.Name, Service: sv.Service, Image: sv.Image})
			}
		}
		if len(wanted) == 0 {
			continue
		}

		detail, err := api.GetStack(ctx, st.Name)
		if err != nil {
			found = append(found, withProblem(wanted, "lettura dello stack: "+err.Error())...)
			continue
		}
		running, err := api.ListStackServices(ctx, st.Name)
		if err != nil {
			found = append(found, withProblem(wanted, "lettura dei servizi: "+err.Error())...)
			continue
		}

		for _, c := range wanted {
			c = resolveDigests(c, detail, running)
			if c.Problem == "" && c.Current == c.Candidate {
				continue // Komodo shows the update, but the digests are equal: nothing to compare
			}
			found = append(found, c)
		}
	}
	return found, nil
}

func withProblem(cands []candidate, problem string) []candidate {
	out := make([]candidate, len(cands))
	for i, c := range cands {
		c.Problem = problem
		out[i] = c
	}
	return out
}

func resolveDigests(c candidate, detail stackDetail, running []stackService) candidate {
	var latest string
	for _, ls := range detail.Info.LatestServices {
		if ls.ServiceName == c.Service && ls.ImageDigest != nil {
			latest = *ls.ImageDigest
		}
	}
	if latest == "" {
		c.Problem = "digest della candidata assente in Komodo (poll non ancora passato?)"
		return c
	}
	repo, digest, err := splitDigestRef(latest)
	if err != nil {
		c.Problem = "digest della candidata non valido: " + err.Error()
		return c
	}
	c.Candidate = repo + "@" + digest

	var currents []string
	for _, rs := range running {
		if rs.Service == c.Service {
			currents = rs.ImageDigests
		}
	}
	// An image can have more than one RepoDigest (the same image with different
	// names). Use the digest of the same repo as the candidate.
	for _, ref := range currents {
		curRepo, curDigest, err := splitDigestRef(ref)
		if err == nil && curRepo == repo {
			c.Current = curRepo + "@" + curDigest
			return c
		}
	}
	for _, ref := range currents {
		if curRepo, curDigest, err := splitDigestRef(ref); err == nil {
			c.Current = curRepo + "@" + curDigest
			return c
		}
	}
	c.Problem = "digest dell'immagine attuale assente in Komodo"
	return c
}

// splitDigestRef: "redis:7@sha256:abc" -> ("docker.io/library/redis", "sha256:abc").
// It removes the tag: the digest makes the tag unnecessary. A normalized repo lets
// us compare the short form of image_digests with the long form of latest_services.
func splitDigestRef(ref string) (repo, digest string, err error) {
	name, digest, ok := strings.Cut(ref, "@")
	if !ok || !strings.HasPrefix(digest, "sha256:") || len(digest) != len("sha256:")+64 {
		return "", "", fmt.Errorf("%q non e' nella forma repo@sha256:<64 hex>", ref)
	}
	if i := strings.LastIndex(name, ":"); i > strings.LastIndex(name, "/") {
		name = name[:i]
	}
	return normalizeRepo(name), digest, nil
}

// normalizeRepo applies the Docker rules for names without a registry:
// "redis" -> "docker.io/library/redis", "henrygd/beszel-agent" -> "docker.io/henrygd/beszel-agent".
func normalizeRepo(repo string) string {
	first, _, found := strings.Cut(repo, "/")
	if !found {
		return "docker.io/library/" + repo
	}
	if strings.ContainsAny(first, ".:") || first == "localhost" {
		return repo
	}
	return "docker.io/" + repo
}

// evaluateAll scans the current image and the candidate of each candidate and applies
// "More than current". The results stay in a cache by ref for one run.
func evaluateAll(ctx context.Context, sc scanner, cands []candidate) []outcome {
	cache := map[string]scanResult{}
	scan := func(ref string) (scanResult, error) {
		if r, ok := cache[ref]; ok {
			return r, nil
		}
		r, err := sc.Scan(ctx, ref)
		if err == nil {
			cache[ref] = r
		}
		return r, err
	}

	outcomes := make([]outcome, 0, len(cands))
	for _, c := range cands {
		o := outcome{Stack: c.Stack, Service: c.Service, Image: c.Image, Candidate: c.Candidate}
		if c.Problem != "" {
			o.Verdict, o.Detail = verdictError, c.Problem
			outcomes = append(outcomes, o)
			continue
		}
		cur, err := scan(c.Current)
		if err != nil {
			o.Verdict, o.Detail = verdictError, "scansione dell'immagine attuale: "+err.Error()
			outcomes = append(outcomes, o)
			continue
		}
		cand, err := scan(c.Candidate)
		if err != nil {
			o.Verdict, o.Detail = verdictError, "scansione della candidata: "+err.Error()
			outcomes = append(outcomes, o)
			continue
		}
		o.Verdict, o.Detail = judge(cur, cand)
		outcomes = append(outcomes, o)
	}
	return outcomes
}

// judge: "More than current". The candidate passes if it does not have more
// vulnerabilities in total than the current image (reason: STATO-THE-GRID.md §5.13).
func judge(cur, cand scanResult) (verdict, detail string) {
	detail = counts(cur, cand)
	// If Trivy does not identify the OS, it does not scan the OS packages and
	// it shows 0 instead of an error. That is a false PASS.
	if cur.OS != "" && cand.OS == "" {
		return verdictError, fmt.Sprintf("   Trivy non riconosce il sistema della nuova versione (l'attuale e' %s): conteggio non confrontabile\n%s", cur.OS, detail)
	}
	if cur.OS != cand.OS {
		detail += fmt.Sprintf("\n   Sistema: %s -> %s", cur.OS, cand.OS)
	}
	if fresh := newSerious(cur, cand); len(fresh) > 0 {
		detail += "\n   ⚠️ " + freshSummary(fresh)
	}
	if cand.Total <= cur.Total {
		return verdictPass, detail
	}
	return verdictBlock, detail
}

// counts: two lines of the message, the total and the serious (CRITICAL+HIGH) vulnerabilities.
func counts(cur, cand scanResult) string {
	return fmt.Sprintf("   Vulnerabilità: %d → %d (%s)\n   Gravi (Critical+High): %d → %d",
		cur.Total, cand.Total, trend(cur.Total, cand.Total), serious(cur), serious(cand))
}

func serious(r scanResult) int { return r.BySeverity["CRITICAL"] + r.BySeverity["HIGH"] }

func trend(cur, cand int) string {
	switch {
	case cand < cur:
		return "meglio"
	case cand > cur:
		return "peggio"
	}
	return "uguale"
}

// newSerious returns the CRITICAL/HIGH ids that are only in the candidate, sorted.
func newSerious(cur, cand scanResult) []string {
	var ids []string
	for id := range cand.Serious {
		if !cur.Serious[id] {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

func freshSummary(ids []string) string {
	const maxShown = 5
	noun := "grave nuova"
	if len(ids) > 1 {
		noun = "gravi nuove"
	}
	shown := ids
	if len(ids) > maxShown {
		shown = ids[:maxShown]
	}
	text := fmt.Sprintf("%d %s: %s", len(ids), noun, strings.Join(shown, ", "))
	if len(ids) > maxShown {
		text += fmt.Sprintf(" (+%d altre)", len(ids)-maxShown)
	}
	return text
}

// outcomeLine is the block of one service in the message. An icon replaces the
// verdict word (the state file keeps the word).
func outcomeLine(o outcome) string {
	icon := map[string]string{verdictPass: "✅", verdictBlock: "⛔", verdictError: "❌"}[o.Verdict]
	detail := o.Detail
	if !strings.HasPrefix(detail, "   ") {
		detail = "   " + detail // an error text of one line
	}
	return fmt.Sprintf("%s %s (%s)\n%s", icon, o.key(), o.Image, detail)
}
