package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// LockedModel is one approved model. The digest is the identity: a tag can
// get new content, a digest cannot.
type LockedModel struct {
	Tag     string `json:"tag"`
	Digest  string `json:"digest"`
	VRAMMiB int    `json:"vram_mib"`
}

// Lock is the content of models.lock.json: the model allowlist.
type Lock struct {
	Models []LockedModel `json:"models"`
}

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

// LoadLock reads and checks the lock file.
func LoadLock(path string) (*Lock, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read models lock: %w", err)
	}
	lock, err := ParseLock(raw)
	if err != nil {
		return nil, fmt.Errorf("models lock %s: %w", path, err)
	}
	return lock, nil
}

// ParseLock decodes a lock document.
func ParseLock(raw []byte) (*Lock, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var lock Lock
	if err := dec.Decode(&lock); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	seen := map[string]bool{}
	for i := range lock.Models {
		m := &lock.Models[i]
		m.Digest = NormalizeDigest(m.Digest)
		switch {
		case m.Tag == "":
			return nil, fmt.Errorf("model %d: the tag is empty", i)
		case seen[m.Tag]:
			return nil, fmt.Errorf("model %q: the tag is in the lock two times", m.Tag)
		case IsCloudTag(m.Tag):
			return nil, fmt.Errorf("model %q: cloud models are not permitted", m.Tag)
		case !digestPattern.MatchString(m.Digest):
			return nil, fmt.Errorf("model %q: the digest is not 64 hexadecimal characters", m.Tag)
		case m.VRAMMiB <= 0:
			return nil, fmt.Errorf("model %q: vram_mib must be more than 0", m.Tag)
		}
		seen[m.Tag] = true
	}
	return &lock, nil
}

// Find returns the lock entry of a tag.
func (l *Lock) Find(tag string) (LockedModel, bool) {
	for _, m := range l.Models {
		if m.Tag == tag {
			return m, true
		}
	}
	return LockedModel{}, false
}

// NormalizeDigest gives a digest as lower case hexadecimal with no prefix.
func NormalizeDigest(digest string) string {
	return strings.TrimPrefix(strings.ToLower(strings.TrimSpace(digest)), "sha256:")
}

// IsCloudTag reports if a tag names a model that runs on a remote service.
func IsCloudTag(tag string) bool {
	lower := strings.ToLower(tag)
	return strings.HasSuffix(lower, "-cloud") || strings.HasSuffix(lower, ":cloud")
}
