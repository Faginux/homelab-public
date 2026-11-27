// Package eval runs a set of cases with known answers and measures the
// results against the thresholds of the plan (the model bake-off).
//
// The cases are outside the repository. Each case goes through the same
// path as a normal call: path policy, redaction, model lock, VRAM check.
package eval

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"localllm/internal/config"
	"localllm/internal/ollama"
	"localllm/internal/tasks"
)

// Thresholds of the plan, section 8 (M4).
const (
	MinValidRate     = 0.98
	MinAccuracy      = 0.85
	MinFactRecall    = 0.80
	MaxP95           = 30 * time.Second
	bytesPerMebibyte = 1 << 20
)

// Case is one case file.
type Case struct {
	Name   string        `json:"name"`
	Task   string        `json:"task"`
	Style  string        `json:"style,omitempty"`
	Input  string        `json:"input"`
	Fields []tasks.Field `json:"fields,omitempty"`
	Labels []string      `json:"labels,omitempty"`
	// LabelDescriptions gives an optional description for each label name.
	// The names and the expected label do not change.
	LabelDescriptions map[string]string `json:"label_descriptions,omitempty"`
	Expect            Expect            `json:"expect"`
}

// requestLabels gives the labels of a case in the form of a classify call:
// "name" or "name: description".
func (c Case) requestLabels() []string {
	if len(c.LabelDescriptions) == 0 {
		return c.Labels
	}
	labels := make([]string, len(c.Labels))
	for i, name := range c.Labels {
		labels[i] = name
		if d := c.LabelDescriptions[name]; d != "" {
			labels[i] = name + ": " + d
		}
	}
	return labels
}

// Expect is the known answer of a case.
type Expect struct {
	// Label is the correct label of a classify case.
	Label string `json:"label,omitempty"`
	// Facts are texts that the result must contain.
	Facts []string `json:"facts,omitempty"`
	// Forbidden are texts that the result must not contain: a fact that
	// is not in the input.
	Forbidden []string `json:"forbidden,omitempty"`
}

// Runner runs one task call.
type Runner interface {
	Run(ctx context.Context, req tasks.Request) tasks.Envelope
}

// Loaded returns the models in memory. Eval reads the VRAM use from it.
type Loaded func(ctx context.Context) ([]ollama.LoadedModel, error)

// CaseResult is the result of one case.
type CaseResult struct {
	Name           string   `json:"name"`
	Task           string   `json:"task"`
	Status         string   `json:"status"`
	Reason         string   `json:"reason,omitempty"`
	Model          string   `json:"model,omitempty"`
	DurationMs     int64    `json:"duration_ms"`
	GotLabel       string   `json:"got_label,omitempty"`
	MissingFacts   []string `json:"missing_facts,omitempty"`
	ForbiddenFound []string `json:"forbidden_found,omitempty"`
}

// TaskReport has the numbers of one group of cases.
type TaskReport struct {
	Cases int `json:"cases"`
	// NotRun counts the cases that the model did not get: busy, engine
	// down, refused input. They are not in the rates.
	NotRun        int     `json:"not_run"`
	Valid         int     `json:"valid"`
	ValidRate     float64 `json:"valid_rate"`
	Labelled      int     `json:"labelled,omitempty"`
	Accuracy      float64 `json:"accuracy,omitempty"`
	Facts         int     `json:"facts,omitempty"`
	FactRecall    float64 `json:"fact_recall,omitempty"`
	ForbiddenHits int     `json:"forbidden_hits"`
	P50Ms         int64   `json:"p50_ms"`
	P95Ms         int64   `json:"p95_ms"`
	Pass          bool    `json:"pass"`

	correct    int
	factsFound int
	durations  []int64
}

// Report is the result of an eval run.
type Report struct {
	Cases         int                    `json:"cases"`
	Models        []string               `json:"models"`
	Groups        map[string]*TaskReport `json:"groups"`
	PeakVRAMMiB   int64                  `json:"peak_model_vram_mib"`
	VRAMBudgetMiB int                    `json:"vram_budget_mib"`
	Pass          bool                   `json:"pass"`
	Problems      []string               `json:"problems"`
	Failures      []CaseResult           `json:"failures"`
}

// LoadCases reads all the *.json files of a folder. The input path of a
// case is relative to the folder.
func LoadCases(dir string) ([]Case, error) {
	names, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, fmt.Errorf("eval: list the cases: %w", err)
	}
	sort.Strings(names)
	var cases []Case
	for _, name := range names {
		raw, err := os.ReadFile(name)
		if err != nil {
			return nil, fmt.Errorf("eval: read the case: %w", err)
		}
		var c Case
		if err := json.Unmarshal(raw, &c); err != nil {
			return nil, fmt.Errorf("eval: case %s: %w", filepath.Base(name), err)
		}
		if c.Name == "" {
			c.Name = strings.TrimSuffix(filepath.Base(name), ".json")
		}
		if c.Input == "" || filepath.IsAbs(c.Input) {
			return nil, fmt.Errorf("eval: case %s: the input must be a path relative to the case folder", c.Name)
		}
		for name := range c.LabelDescriptions {
			if !slices.Contains(c.Labels, name) {
				return nil, fmt.Errorf("eval: case %s: the description of %q is for a label that is not in the list", c.Name, name)
			}
		}
		c.Input = filepath.Join(dir, c.Input)
		cases = append(cases, c)
	}
	if len(cases) == 0 {
		return nil, fmt.Errorf("eval: the folder %s has no case files", dir)
	}
	return cases, nil
}

// group names the cases that have the same thresholds.
func group(c Case) string {
	if c.Task == config.TaskSummarize && c.Style == tasks.StyleLog {
		return "log_digest"
	}
	return c.Task
}

// Run runs all cases and makes the report.
func Run(ctx context.Context, runner Runner, loaded Loaded, cases []Case, tier string, budgetMiB int) Report {
	report := Report{
		Cases: len(cases), Groups: map[string]*TaskReport{}, VRAMBudgetMiB: budgetMiB,
		Problems: []string{}, Failures: []CaseResult{},
	}
	models := map[string]bool{}

	for _, c := range cases {
		env := runner.Run(ctx, tasks.Request{
			Task: c.Task, Style: c.Style, Paths: []string{c.Input},
			Fields: c.Fields, Labels: c.requestLabels(), Tier: tier,
		})
		result := CaseResult{Name: c.Name, Task: c.Task, Status: env.Status, Reason: env.Reason, Model: env.Model}
		if env.Stats != nil {
			result.DurationMs = env.Stats.DurationMs
		}
		if env.Model != "" {
			models[env.Model] = true
		}
		if models, err := loaded(ctx); err == nil {
			for _, m := range models {
				report.PeakVRAMMiB = max(report.PeakVRAMMiB, m.SizeVRAM/bytesPerMebibyte)
			}
		}

		g := report.Groups[group(c)]
		if g == nil {
			g = &TaskReport{}
			report.Groups[group(c)] = g
		}
		g.Cases++
		failed := score(c, env, &result, g)
		if failed {
			report.Failures = append(report.Failures, result)
		}
	}

	for model := range models {
		report.Models = append(report.Models, model)
	}
	sort.Strings(report.Models)
	report.finish()
	return report
}

// score adds one case to its group. It returns true when the case failed.
func score(c Case, env tasks.Envelope, result *CaseResult, g *TaskReport) bool {
	switch env.Status {
	case tasks.StatusOK:
	case tasks.StatusSchemaInvalid:
		// The model got the input and gave a bad answer: this counts
		// against the validity rate.
		g.durations = append(g.durations, result.DurationMs)
		return true
	default:
		g.NotRun++
		return true
	}
	g.Valid++
	g.durations = append(g.durations, result.DurationMs)

	raw, _ := json.Marshal(env.Result)
	text := strings.ToLower(string(raw))
	failed := false

	if c.Expect.Label != "" {
		g.Labelled++
		result.GotLabel = firstLabel(raw)
		if result.GotLabel == c.Expect.Label {
			g.correct++
		} else {
			failed = true
		}
	}
	for _, fact := range c.Expect.Facts {
		g.Facts++
		if strings.Contains(text, strings.ToLower(fact)) {
			g.factsFound++
		} else {
			result.MissingFacts = append(result.MissingFacts, fact)
			failed = true
		}
	}
	for _, forbidden := range c.Expect.Forbidden {
		if strings.Contains(text, strings.ToLower(forbidden)) {
			g.ForbiddenHits++
			result.ForbiddenFound = append(result.ForbiddenFound, forbidden)
			failed = true
		}
	}
	return failed
}

func firstLabel(raw []byte) string {
	var result tasks.Classifications
	if json.Unmarshal(raw, &result) != nil || len(result.Results) == 0 {
		return ""
	}
	return result.Results[0].Label
}

// finish computes the rates and compares them with the thresholds.
func (r *Report) finish() {
	r.Pass = true
	problem := func(format string, args ...any) {
		r.Pass = false
		r.Problems = append(r.Problems, fmt.Sprintf(format, args...))
	}

	names := make([]string, 0, len(r.Groups))
	for name := range r.Groups {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		g := r.Groups[name]
		g.Pass = true
		fail := func(format string, args ...any) {
			g.Pass = false
			problem(name+": "+format, args...)
		}

		if g.NotRun > 0 {
			fail("%d cases did not run", g.NotRun)
		}
		if ran := g.Cases - g.NotRun; ran > 0 {
			g.ValidRate = rate(g.Valid, ran)
			if g.ValidRate < MinValidRate {
				fail("JSON validity %.0f%% is below %.0f%%", g.ValidRate*100, MinValidRate*100)
			}
		}
		if g.Labelled > 0 {
			g.Accuracy = rate(g.correct, g.Labelled)
			if g.Accuracy < MinAccuracy {
				fail("accuracy %.0f%% is below %.0f%%", g.Accuracy*100, MinAccuracy*100)
			}
		}
		if g.Facts > 0 {
			g.FactRecall = rate(g.factsFound, g.Facts)
			if g.FactRecall < MinFactRecall {
				fail("key-fact recall %.0f%% is below %.0f%%", g.FactRecall*100, MinFactRecall*100)
			}
		}
		if g.ForbiddenHits > 0 {
			fail("%d invented facts", g.ForbiddenHits)
		}
		g.P50Ms = percentile(g.durations, 0.50)
		g.P95Ms = percentile(g.durations, 0.95)
		if g.P95Ms > MaxP95.Milliseconds() {
			fail("p95 latency %d ms is above %d ms", g.P95Ms, MaxP95.Milliseconds())
		}
	}
	if r.PeakVRAMMiB > int64(r.VRAMBudgetMiB) {
		problem("peak model VRAM %d MiB is above the budget of %d MiB", r.PeakVRAMMiB, r.VRAMBudgetMiB)
	}
}

func rate(part, whole int) float64 {
	return math.Round(float64(part)/float64(whole)*1000) / 1000
}

// percentile uses the nearest-rank method.
func percentile(values []int64, p float64) int64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]int64(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	rank := int(math.Ceil(p * float64(len(sorted))))
	return sorted[max(rank, 1)-1]
}
