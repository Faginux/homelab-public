// Package gpu reads the free video memory before a model call (layer L8 of
// the plan). It contains the only process start of localllm (layer L7): the
// program nvidia-smi, with a constant argument list. A guard test fails if
// the module gets a different process start.
package gpu

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const queryTimeout = 10 * time.Second

// smiArgs is constant: no value from a caller, a config file or a model
// goes into the command line.
var smiArgs = []string{
	"--query-gpu=memory.total,memory.used,memory.free",
	"--format=csv,noheader,nounits",
}

// Status is the video memory of the first GPU, in MiB.
type Status struct {
	TotalMiB int `json:"total_mib"`
	UsedMiB  int `json:"used_mib"`
	FreeMiB  int `json:"free_mib"`
}

// Query runs nvidia-smi and returns the memory of the first GPU.
func Query(ctx context.Context) (Status, error) {
	path, err := smiPath()
	if err != nil {
		return Status{}, fmt.Errorf("gpu: find nvidia-smi: %w", err)
	}
	ctx, cancel := context.WithTimeout(ctx, queryTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, path, smiArgs...)
	hideWindow(cmd)
	out, err := cmd.Output()
	if err != nil {
		return Status{}, fmt.Errorf("gpu: run nvidia-smi: %w", err)
	}
	return parse(string(out))
}

func parse(out string) (Status, error) {
	line, _, _ := strings.Cut(strings.TrimSpace(out), "\n")
	fields := strings.Split(line, ",")
	if len(fields) != 3 {
		return Status{}, errors.New("gpu: the output of nvidia-smi does not have three fields")
	}
	var values [3]int
	for i, field := range fields {
		n, err := strconv.Atoi(strings.TrimSpace(field))
		if err != nil || n < 0 {
			return Status{}, fmt.Errorf("gpu: field %d of the output of nvidia-smi is not a number", i+1)
		}
		values[i] = n
	}
	return Status{TotalMiB: values[0], UsedMiB: values[1], FreeMiB: values[2]}, nil
}

// Fits reports if a model with the given need can load: the free memory
// must be equal to or more than the need plus the margin.
func Fits(freeMiB, needMiB, marginMiB int) bool {
	return freeMiB >= needMiB+marginMiB
}
