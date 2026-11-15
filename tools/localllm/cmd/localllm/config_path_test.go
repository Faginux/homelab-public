package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultConfigPath(t *testing.T) {
	tests := []struct {
		name   string
		beside bool
		above  bool
		want   string // "beside" or "above"
	}{
		{"file beside the program", true, false, "beside"},
		{"file in the folder above", false, true, "above"},
		{"both files: the nearest wins", true, true, "beside"},
		{"no file: the error names the file beside the program", false, false, "beside"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			data := t.TempDir()
			bin := filepath.Join(data, "bin")
			if err := os.Mkdir(bin, 0o755); err != nil {
				t.Fatal(err)
			}
			paths := map[string]string{
				"beside": filepath.Join(bin, configName),
				"above":  filepath.Join(data, configName),
			}
			for key, make := range map[string]bool{"beside": tt.beside, "above": tt.above} {
				if make {
					if err := os.WriteFile(paths[key], []byte("{}"), 0o644); err != nil {
						t.Fatal(err)
					}
				}
			}
			if got := defaultConfigPath(bin); got != paths[tt.want] {
				t.Errorf("defaultConfigPath = %q, want %q", got, paths[tt.want])
			}
		})
	}
}

func TestResolveConfigPathOrder(t *testing.T) {
	t.Setenv(configEnv, `C:\from\env.json`)
	if got := resolveConfigPath(`C:\from\flag.json`); got != `C:\from\flag.json` {
		t.Errorf("with a flag: %q, want the flag value", got)
	}
	if got := resolveConfigPath(""); got != `C:\from\env.json` {
		t.Errorf("with no flag: %q, want the value of the environment variable", got)
	}
}
