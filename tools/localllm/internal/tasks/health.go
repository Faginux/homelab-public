package tasks

import (
	"context"
	"errors"

	"localllm/internal/config"
	"localllm/internal/gpu"
	"localllm/internal/ollama"
)

// Model states in a health report.
const (
	ModelReady          = "ready"
	ModelNotInstalled   = "not_installed"
	ModelDigestMismatch = "digest_mismatch"
)

// ModelHealth is the state of one model of the lock.
type ModelHealth struct {
	Tag     string `json:"tag"`
	State   string `json:"state"`
	VRAMMiB int    `json:"vram_mib"`
	Loaded  bool   `json:"loaded"`
	// Fits is true when the model is in memory or can load now.
	Fits bool `json:"fits"`
}

// Health is the result of the health report.
type Health struct {
	Engine        string        `json:"engine"`
	Version       string        `json:"version,omitempty"`
	Endpoint      string        `json:"endpoint"`
	Cloud         string        `json:"cloud"`
	CloudModels   []string      `json:"cloud_models_installed"`
	GPU           *gpu.Status   `json:"gpu,omitempty"`
	GPUError      string        `json:"gpu_error,omitempty"`
	VRAMBudgetMiB int           `json:"vram_budget_mib"`
	VRAMMarginMiB int           `json:"vram_margin_mib"`
	Loaded        []string      `json:"loaded_models"`
	Models        []ModelHealth `json:"locked_models"`
}

// Health reports the state of the engine, the GPU and the locked models. It
// reads only: it loads no model and writes no audit record.
func (r *Runner) Health(ctx context.Context) Envelope {
	env := Envelope{Label: OutputLabel, Status: StatusOK, Task: TaskHealth}
	health := Health{
		Engine:        "up",
		Endpoint:      r.Config.OllamaURL,
		Cloud:         "no cloud: the engine address is loopback and the lock refuses cloud models",
		CloudModels:   []string{},
		VRAMBudgetMiB: r.Config.VRAMBudgetMiB,
		VRAMMarginMiB: r.Config.VRAMMarginMiB,
		Loaded:        []string{},
		Models:        []ModelHealth{},
	}

	free := -1
	if status, err := r.QueryGPU(ctx); err != nil {
		health.GPUError = "the free VRAM is not available"
	} else {
		health.GPU = &status
		free = status.FreeMiB
	}

	version, err := r.Engine.Version(ctx)
	var installed []ollama.Model
	var loaded []ollama.LoadedModel
	if err == nil {
		installed, err = r.Engine.Models(ctx)
	}
	if err == nil {
		loaded, err = r.Engine.Loaded(ctx)
	}
	if err != nil {
		f := engineFailure(err)
		health.Engine = "down"
		env.Status, env.Reason = f.status, f.reason
		env.Result = health
		return env
	}
	health.Version = version

	for _, m := range loaded {
		health.Loaded = append(health.Loaded, m.Name)
	}
	for _, m := range installed {
		if config.IsCloudTag(m.Name) {
			health.CloudModels = append(health.CloudModels, m.Name)
			health.Cloud = "cloud models are installed: the lock refuses them, but remove them"
		}
	}
	for _, locked := range r.Lock.Models {
		state := ModelReady
		switch err := verifyInstalled(installed, locked); {
		case errors.Is(err, ollama.ErrDigestMismatch):
			state = ModelDigestMismatch
		case err != nil:
			state = ModelNotInstalled
		}
		inMemory := isLoaded(loaded, locked.Tag)
		health.Models = append(health.Models, ModelHealth{
			Tag:     locked.Tag,
			State:   state,
			VRAMMiB: locked.VRAMMiB,
			Loaded:  inMemory,
			Fits: state == ModelReady && locked.VRAMMiB <= r.Config.VRAMBudgetMiB &&
				(inMemory || gpu.Fits(free, locked.VRAMMiB, r.Config.VRAMMarginMiB)),
		})
	}
	env.Result = health
	return env
}

func verifyInstalled(installed []ollama.Model, locked config.LockedModel) error {
	for _, m := range installed {
		if m.Name != locked.Tag {
			continue
		}
		if config.NormalizeDigest(m.Digest) != locked.Digest {
			return ollama.ErrDigestMismatch
		}
		return nil
	}
	return ollama.ErrModelNotInstalled
}
