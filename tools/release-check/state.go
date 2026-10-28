package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

func loadState(path string) (releaseState, error) {
	st := releaseState{Images: map[string]record{}}
	if path == "" {
		return st, nil // dry run without a state file
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil // first round
	}
	if err != nil {
		return st, fmt.Errorf("read state: %w", err)
	}
	if err := json.Unmarshal(data, &st); err != nil {
		return st, fmt.Errorf("state %s unreadable: %w", path, err)
	}
	if st.Images == nil {
		st.Images = map[string]record{}
	}
	return st, nil
}

// saveState writes a temporary file and renames it: an interrupted round never
// leaves a half state.
func saveState(path string, st releaseState) error {
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*.json")
	if err != nil {
		return fmt.Errorf("write state: %w", err)
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write state: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("write state: %w", err)
	}
	return os.Rename(tmp.Name(), path)
}
