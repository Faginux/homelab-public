package eval

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"localllm/internal/config"
	"localllm/internal/ollama"
	"localllm/internal/tasks"
)

// scriptedRunner gives the result that the test wrote for each input file.
type scriptedRunner struct {
	results map[string]tasks.Envelope
	seen    []tasks.Request
}

func (r *scriptedRunner) Run(_ context.Context, req tasks.Request) tasks.Envelope {
	r.seen = append(r.seen, req)
	env, ok := r.results[filepath.Base(req.Paths[0])]
	if !ok {
		return tasks.Envelope{Status: tasks.StatusRefused, Reason: "not_found"}
	}
	env.Model = "small:1"
	return env
}

func ok(result any, ms int64) tasks.Envelope {
	return tasks.Envelope{Status: tasks.StatusOK, Result: result, Stats: &tasks.Stats{DurationMs: ms}}
}

func label(l string) tasks.Classifications {
	return tasks.Classifications{Results: []tasks.Classification{{File: "x", Label: l, Confidence: "high"}}}
}

func classifyCases(n int) []Case {
	var cases []Case
	for i := 0; i < n; i++ {
		cases = append(cases, Case{Name: fmt.Sprintf("c%02d", i), Task: config.TaskClassify, Input: fmt.Sprintf("c%02d.txt", i),
			Labels: []string{"logs", "docs"}, Expect: Expect{Label: "logs"}})
	}
	return cases
}

func TestRunScoresTheGroups(t *testing.T) {
	cases := append(classifyCases(20),
		Case{Name: "digest", Task: config.TaskSummarize, Style: tasks.StyleLog, Input: "digest.log",
			Expect: Expect{Facts: []string{"Connection Refused", "disk full"}, Forbidden: []string{"kernel panic"}}},
		Case{Name: "extract", Task: config.TaskExtract, Input: "notes.md",
			Fields: []tasks.Field{{Name: "version", Type: "string"}}, Expect: Expect{Facts: []string{"3.4.1"}}},
	)
	runner := &scriptedRunner{results: map[string]tasks.Envelope{
		"digest.log": ok(map[string]any{"patterns": []string{"connection refused each minute"}}, 4000),
		"notes.md":   ok(map[string]any{"fields": map[string]string{"version": "3.4.1"}}, 900),
	}}
	for i := 0; i < 20; i++ {
		got := "logs"
		if i >= 18 { // 18 of 20 correct: 90 percent
			got = "docs"
		}
		runner.results[fmt.Sprintf("c%02d.txt", i)] = ok(label(got), int64(100*(i+1)))
	}
	loaded := func(context.Context) ([]ollama.LoadedModel, error) {
		return []ollama.LoadedModel{{Name: "small:1", SizeVRAM: 3158 << 20}}, nil
	}

	report := Run(context.Background(), runner, loaded, cases, config.TierS, 7926)

	classify := report.Groups["classify"]
	if classify.Cases != 20 || classify.Valid != 20 || classify.ValidRate != 1 || classify.Accuracy != 0.9 || !classify.Pass {
		t.Errorf("classify = %+v", classify)
	}
	if classify.P50Ms != 1000 || classify.P95Ms != 1900 {
		t.Errorf("classify p50 = %d, p95 = %d, want 1000 and 1900", classify.P50Ms, classify.P95Ms)
	}
	digest := report.Groups["log_digest"]
	if digest.Facts != 2 || digest.FactRecall != 0.5 || digest.Pass {
		t.Errorf("log digest = %+v, want recall 0.5 and no pass", digest)
	}
	extract := report.Groups["extract"]
	if extract.FactRecall != 1 || !extract.Pass {
		t.Errorf("extract = %+v", extract)
	}
	if report.PeakVRAMMiB != 3158 || report.Pass {
		t.Errorf("peak VRAM = %d, pass = %v, want 3158 and false", report.PeakVRAMMiB, report.Pass)
	}
	if len(report.Models) != 1 || report.Models[0] != "small:1" {
		t.Errorf("models = %v", report.Models)
	}
	// Two wrong labels and the digest with a missing fact.
	if len(report.Failures) != 3 {
		t.Errorf("failures = %d, want 3: %+v", len(report.Failures), report.Failures)
	}
	for _, f := range report.Failures {
		if f.Name == "digest" && (len(f.MissingFacts) != 1 || f.MissingFacts[0] != "disk full") {
			t.Errorf("digest failure = %+v", f)
		}
	}
	if runner.seen[0].Tier != config.TierS || len(runner.seen[0].Labels) != 2 {
		t.Errorf("request = %+v", runner.seen[0])
	}
}

func TestThresholds(t *testing.T) {
	tests := []struct {
		name        string
		setup       func(r *scriptedRunner, cases []Case) []Case
		loadedMiB   int64
		wantPass    bool
		wantProblem string
	}{
		{"all correct", nil, 3000, true, ""},
		{"accuracy below 85 percent", func(r *scriptedRunner, cases []Case) []Case {
			for i := 0; i < 4; i++ {
				r.results[fmt.Sprintf("c%02d.txt", i)] = ok(label("docs"), 100)
			}
			return cases
		}, 3000, false, "accuracy 80%"},
		{"one bad answer in twenty", func(r *scriptedRunner, cases []Case) []Case {
			r.results["c00.txt"] = tasks.Envelope{Status: tasks.StatusSchemaInvalid, Stats: &tasks.Stats{DurationMs: 100}}
			return cases
		}, 3000, false, "JSON validity 95%"},
		{"a case that did not run", func(r *scriptedRunner, cases []Case) []Case {
			r.results["c00.txt"] = tasks.Envelope{Status: tasks.StatusBusy}
			return cases
		}, 3000, false, "1 cases did not run"},
		{"invented fact", func(r *scriptedRunner, cases []Case) []Case {
			cases[0].Expect.Forbidden = []string{"LOGS"}
			return cases
		}, 3000, false, "1 invented facts"},
		{"slow answers", func(r *scriptedRunner, cases []Case) []Case {
			for i := 0; i < 2; i++ {
				r.results[fmt.Sprintf("c%02d.txt", i)] = ok(label("logs"), 31000)
			}
			return cases
		}, 3000, false, "p95 latency 31000 ms"},
		{"model above the VRAM budget", nil, 8000, false, "peak model VRAM 8000 MiB"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cases := classifyCases(20)
			runner := &scriptedRunner{results: map[string]tasks.Envelope{}}
			for i := range cases {
				runner.results[cases[i].Input] = ok(label("logs"), 100)
			}
			if tt.setup != nil {
				cases = tt.setup(runner, cases)
			}
			loaded := func(context.Context) ([]ollama.LoadedModel, error) {
				return []ollama.LoadedModel{{SizeVRAM: tt.loadedMiB << 20}}, nil
			}
			report := Run(context.Background(), runner, loaded, cases, "", 7926)
			if report.Pass != tt.wantPass {
				t.Errorf("pass = %v, want %v (problems: %v)", report.Pass, tt.wantPass, report.Problems)
			}
			if tt.wantProblem != "" && !strings.Contains(strings.Join(report.Problems, "\n"), tt.wantProblem) {
				t.Errorf("problems = %v, want one with %q", report.Problems, tt.wantProblem)
			}
		})
	}
}

func TestPercentile(t *testing.T) {
	tests := []struct {
		name   string
		values []int64
		p      float64
		want   int64
	}{
		{"empty", nil, 0.95, 0},
		{"one value", []int64{7}, 0.95, 7},
		{"p50 of four", []int64{40, 10, 30, 20}, 0.50, 20},
		{"p95 of twenty", []int64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}, 0.95, 19},
		{"p95 of fifteen", []int64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}, 0.95, 15},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := percentile(tt.values, tt.p); got != tt.want {
				t.Errorf("percentile = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestLoadCases(t *testing.T) {
	write := func(t *testing.T, dir, name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Run("valid folder", func(t *testing.T) {
		dir := t.TempDir()
		write(t, dir, "b-case.json", `{"task":"classify","input":"b.txt","labels":["logs","docs"],"expect":{"label":"logs"}}`)
		write(t, dir, "a-case.json", `{"name":"first","task":"summarize","style":"log","input":"sub/a.log","expect":{"facts":["x"]}}`)
		write(t, dir, "notes.txt", "not a case")
		cases, err := LoadCases(dir)
		if err != nil {
			t.Fatalf("LoadCases: %v", err)
		}
		if len(cases) != 2 || cases[0].Name != "first" || cases[1].Name != "b-case" {
			t.Fatalf("cases = %+v", cases)
		}
		if cases[0].Input != filepath.Join(dir, "sub", "a.log") {
			t.Errorf("input = %q, want a path in the case folder", cases[0].Input)
		}
	})
	bad := []struct {
		name    string
		content string
	}{
		{"not JSON", `{"task":`},
		{"no input", `{"task":"classify"}`},
		{"absolute input", `{"task":"classify","input":"` + strings.ReplaceAll(filepath.Join(t.TempDir(), "x.txt"), `\`, `\\`) + `"}`},
		{"description of a label that is not in the list", `{"task":"classify","input":"b.txt","labels":["logs","docs"],"label_descriptions":{"notes":"text notes"},"expect":{"label":"logs"}}`},
	}
	for _, tt := range bad {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			write(t, dir, "case.json", tt.content)
			if _, err := LoadCases(dir); err == nil {
				t.Error("LoadCases accepted the folder, want an error")
			}
		})
	}
	t.Run("empty folder", func(t *testing.T) {
		if _, err := LoadCases(t.TempDir()); err == nil {
			t.Error("LoadCases accepted an empty folder")
		}
	})
}

func TestLabelDescriptionsGoIntoTheRequest(t *testing.T) {
	c := Case{Name: "k", Task: config.TaskClassify, Input: "k.txt",
		Labels:            []string{"Bollette", "Casa", "Fisco"},
		LabelDescriptions: map[string]string{"Bollette": "luce, gas, acqua, internet", "Fisco": "tasse"},
		Expect:            Expect{Label: "Bollette"}}
	runner := &scriptedRunner{results: map[string]tasks.Envelope{"k.txt": ok(label("Bollette"), 500)}}
	loaded := func(context.Context) ([]ollama.LoadedModel, error) { return nil, nil }

	report := Run(context.Background(), runner, loaded, []Case{c}, config.TierS, 7926)

	want := []string{"Bollette: luce, gas, acqua, internet", "Casa", "Fisco: tasse"}
	if got := runner.seen[0].Labels; !slices.Equal(got, want) {
		t.Errorf("request labels = %q, want %q", got, want)
	}
	if g := report.Groups[config.TaskClassify]; g == nil || g.Labelled != 1 || g.Accuracy != 1 {
		t.Errorf("the case with the expected label name did not pass: %+v", report.Groups[config.TaskClassify])
	}
}
