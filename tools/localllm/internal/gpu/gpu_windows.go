package gpu

import (
	"os/exec"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/windows"
)

// smiPath gives the full path in the system directory. The driver installs
// nvidia-smi.exe there. A search in PATH or in the current directory could
// start a different program with the same name.
func smiPath() (string, error) {
	dir, err := windows.GetSystemDirectory()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "nvidia-smi.exe"), nil
}

// hideWindow prevents a console window when the MCP server has no console.
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
}
