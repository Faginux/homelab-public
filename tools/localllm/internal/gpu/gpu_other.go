//go:build !windows

package gpu

import "os/exec"

func smiPath() (string, error) {
	return exec.LookPath("nvidia-smi")
}

func hideWindow(*exec.Cmd) {}
