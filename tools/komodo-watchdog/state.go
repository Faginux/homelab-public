package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// targetState is the state of a target (a Server, or the API) between two
// runs. A healthy target has no item in the state.
type targetState struct {
	Failures int       `json:"failures"` // failed checks in a row
	Since    time.Time `json:"since"`    // first failed check of the series
	Alerted  bool      `json:"alerted"`  // alert already sent for this series
}

type watchState struct {
	API     targetState            `json:"api"`
	Servers map[string]targetState `json:"servers"`
}

func loadState(path string) (watchState, error) {
	st := watchState{Servers: map[string]targetState{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil // first run
	}
	if err != nil {
		return st, fmt.Errorf("lettura stato: %w", err)
	}
	if err := json.Unmarshal(data, &st); err != nil {
		return st, fmt.Errorf("stato %s non leggibile: %w", path, err)
	}
	if st.Servers == nil {
		st.Servers = map[string]targetState{}
	}
	return st, nil
}

// saveState writes a temporary file and renames it: an interrupted run does not
// leave a half-written state.
func saveState(path string, st watchState) error {
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".state-*.json")
	if err != nil {
		return fmt.Errorf("scrittura stato: %w", err)
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("scrittura stato: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("scrittura stato: %w", err)
	}
	return os.Rename(tmp.Name(), path)
}
