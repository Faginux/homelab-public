//go:build !windows

package policy

import (
	"errors"
	"os"
)

// The real-path check uses Windows handle functions. On a different system
// the policy refuses all files, because a weaker check is not acceptable.

func openFile(path string) (*os.File, fileFacts, error) {
	return nil, fileFacts{}, deny(CodeUnsupported, path, "the path policy runs only on Windows")
}

func canonicalDir(string) (string, error) {
	return "", errors.New("the path policy runs only on Windows")
}
