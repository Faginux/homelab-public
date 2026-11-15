// Package policy is the input gate of localllm (layer L3 of the plan).
//
// The caller is not trusted for paths: it can make an error, or it can follow
// an instruction that it read in a log. Thus each file goes through the same
// sequence: examine the path text, open the file, read the real path and the
// attributes from the open handle, check them, then read from that same
// handle. The check and the read use one handle, so a link that changes
// between the two steps has no effect.
package policy

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// Refusal codes. They are stable: callers and tests compare them.
const (
	CodeInvalidPath  = "invalid_path"
	CodeDeniedName   = "denied_name"
	CodeOutsideRoots = "outside_roots"
	CodeNotFound     = "not_found"
	CodeOpenFailed   = "open_failed"
	CodeNotRegular   = "not_regular"
	CodeHardLink     = "hard_link"
	CodeTooLarge     = "too_large"
	CodeCallTooLarge = "call_too_large"
	CodeTooManyFiles = "too_many_files"
	CodeBinary       = "binary"
	CodeUnsupported  = "unsupported_platform"
)

// MaxFilesPerCall is the largest number of files in one call.
const MaxFilesPerCall = 100

// Error is a refusal. It never contains file content.
type Error struct {
	Code   string
	Path   string
	Detail string
}

func (e *Error) Error() string {
	if e.Path == "" {
		return fmt.Sprintf("policy: %s: %s", e.Code, e.Detail)
	}
	return fmt.Sprintf("policy: %s: %s: %s", e.Code, e.Path, e.Detail)
}

func deny(code, path, detail string) *Error {
	return &Error{Code: code, Path: path, Detail: detail}
}

// CodeOf returns the refusal code of an error, or an empty string.
func CodeOf(err error) string {
	var refusal *Error
	if errors.As(err, &refusal) {
		return refusal.Code
	}
	return ""
}

// File is an input file that passed the policy.
type File struct {
	Requested string
	Canonical string
	Name      string
	Text      string
	Bytes     int64
	SHA256    string
}

// fileFacts are the properties that the operating system gives for an open
// handle.
type fileFacts struct {
	canonical string
	regular   bool
	links     uint32
	size      int64
}

// Policy holds the allowed roots and the size limits.
type Policy struct {
	roots        []string
	maxFileBytes int64
	maxCallBytes int64
}

// New makes a policy. A root must be a drive-absolute path, but it is not
// necessary that it exists now: a temporary folder can go away and come
// back. The policy reads the real path of each root at each check, so a
// root that is given with a short name or through a link still agrees with
// the real path of a file. A root that does not exist permits nothing.
func New(roots []string, maxFileBytes, maxCallBytes int64) (*Policy, error) {
	if len(roots) == 0 {
		return nil, errors.New("policy: at least one allowed root is necessary")
	}
	for _, root := range roots {
		if !driveAbsolute.MatchString(root) {
			return nil, fmt.Errorf("policy: the allowed root %q is not a drive-absolute path", root)
		}
	}
	return &Policy{
		roots:        append([]string(nil), roots...),
		maxFileBytes: maxFileBytes,
		maxCallBytes: maxCallBytes,
	}, nil
}

// Roots returns the real paths of the roots that exist now, and the
// configured paths of the roots that are missing or are not a directory.
func (p *Policy) Roots() (resolved, missing []string) {
	for _, root := range p.roots {
		canonical, err := canonicalDir(root)
		if err != nil {
			missing = append(missing, root)
			continue
		}
		resolved = append(resolved, canonical)
	}
	return resolved, missing
}

// Read applies the policy to one path and returns the file text.
func (p *Policy) Read(path string) (*File, error) {
	if err := checkRequested(path); err != nil {
		return nil, err
	}
	f, facts, err := openFile(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	switch {
	case !facts.regular:
		return nil, deny(CodeNotRegular, path, "only a regular file is permitted")
	case !p.underRoot(facts.canonical):
		return nil, deny(CodeOutsideRoots, path, "the real path is not in an allowed root")
	case facts.links > 1:
		// A second name of the same file can be a secret outside the roots.
		return nil, deny(CodeHardLink, path, "the file has more than one hard link")
	case facts.size > p.maxFileBytes:
		return nil, deny(CodeTooLarge, path, fmt.Sprintf("the file is larger than %d bytes", p.maxFileBytes))
	}
	if rule := deniedPath(facts.canonical); rule != "" {
		return nil, deny(CodeDeniedName, path, "the real name agrees with the deny rule "+rule)
	}

	// The limit applies again here, because a log can grow after the size check.
	data, err := io.ReadAll(io.LimitReader(f, p.maxFileBytes+1))
	if err != nil {
		return nil, deny(CodeOpenFailed, path, "the read failed")
	}
	if int64(len(data)) > p.maxFileBytes {
		return nil, deny(CodeTooLarge, path, fmt.Sprintf("the file is larger than %d bytes", p.maxFileBytes))
	}
	text, err := Text(data)
	if err != nil {
		return nil, deny(CodeOf(err), path, "the file is not a text file")
	}
	sum := sha256.Sum256(data)
	parts := splitPath(facts.canonical)
	return &File{
		Requested: path,
		Canonical: facts.canonical,
		Name:      parts[len(parts)-1],
		Text:      text,
		Bytes:     int64(len(data)),
		SHA256:    hex.EncodeToString(sum[:]),
	}, nil
}

// ReadAll applies the policy to each path. One refusal refuses the full
// call: a partial input would give a result that looks complete.
func (p *Policy) ReadAll(paths []string) ([]*File, error) {
	if len(paths) > MaxFilesPerCall {
		return nil, deny(CodeTooManyFiles, "", fmt.Sprintf("one call permits %d files", MaxFilesPerCall))
	}
	var files []*File
	var total int64
	for _, path := range paths {
		file, err := p.Read(path)
		if err != nil {
			return nil, err
		}
		total += file.Bytes
		if total > p.maxCallBytes {
			return nil, deny(CodeCallTooLarge, "", fmt.Sprintf("the files of one call are larger than %d bytes", p.maxCallBytes))
		}
		files = append(files, file)
	}
	return files, nil
}

func (p *Policy) underRoot(canonical string) bool {
	resolved, _ := p.Roots()
	for _, root := range resolved {
		if isUnder(root, canonical) {
			return true
		}
	}
	return false
}

func openError(path string, err error) *Error {
	if errors.Is(err, os.ErrNotExist) {
		return deny(CodeNotFound, path, "the file does not exist")
	}
	// The text of the system error has only the path and the reason.
	return deny(CodeOpenFailed, path, strings.TrimSpace(err.Error()))
}
