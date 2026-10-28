package main

import (
	"fmt"
	"io"
	"io/fs"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const hubRegistry = "registry-1.docker.io"

// imageRef is one parsed `image:` value.
type imageRef struct {
	Registry string // host of the registry API
	Repo     string // path in the registry ("library/mariadb")
	Name     string // short name for config keys and messages ("mariadb", "bitwarden/lite")
	Tag      string
	Digest   string // "sha256:..." or ""
}

func (r imageRef) String() string {
	s := r.Registry + "/" + r.Repo + ":" + r.Tag
	if r.Digest != "" {
		s += "@" + r.Digest
	}
	return s
}

// parseImage splits an image reference. It returns false for a reference with a
// variable (${...}) or without a tag. An unreadable value never becomes a guess.
func parseImage(raw string) (imageRef, bool) {
	if strings.Contains(raw, "$") {
		return imageRef{}, false
	}
	ref := imageRef{}
	rest := raw
	if at := strings.Index(rest, "@"); at >= 0 {
		ref.Digest = rest[at+1:]
		rest = rest[:at]
	}
	if slash := strings.LastIndex(rest, "/"); strings.LastIndex(rest, ":") > slash {
		colon := strings.LastIndex(rest, ":")
		ref.Tag = rest[colon+1:]
		rest = rest[:colon]
	}
	if ref.Tag == "" {
		return imageRef{}, false
	}

	host := ""
	if first, tail, found := strings.Cut(rest, "/"); found &&
		(strings.ContainsAny(first, ".:") || first == "localhost") {
		host, rest = first, tail
	}
	switch host {
	case "", "docker.io", "index.docker.io", hubRegistry:
		ref.Registry = hubRegistry
		if !strings.Contains(rest, "/") {
			rest = "library/" + rest
		}
		ref.Repo = rest
		ref.Name = strings.TrimPrefix(rest, "library/")
	default:
		ref.Registry = host
		ref.Repo = rest
		ref.Name = rest
	}
	return ref, true
}

var imageLineRe = regexp.MustCompile(`^\s*image:\s*(\S+)`)

// imageLines returns the values of the `image:` keys of a compose file. It reads
// text lines only: the tool has no YAML parser and no need for one.
func imageLines(r io.Reader) ([]string, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if m := imageLineRe.FindStringSubmatch(line); m != nil {
			out = append(out, strings.Trim(m[1], `"'`))
		}
	}
	return out, nil
}

type root struct {
	Path string `json:"path"` // relative to the repo root
	Host string `json:"host"` // label in the message ("the-grid")
}

// pin is one image found in a compose file, with where it was found.
type pin struct {
	Ref   imageRef
	Place string // "the-grid bitwarden"
}

type skipped struct {
	Image  string
	Reason string
}

var composeNames = map[string]bool{
	"docker-compose.yml": true, "docker-compose.yaml": true,
	"compose.yml": true, "compose.yaml": true,
}

// scanPins reads every compose file under the roots. An image counts only if it has
// a full version tag or a digest. Floating tags are listed in the second result.
func scanPins(repo fs.FS, roots []root) ([]pin, []skipped, error) {
	var pins []pin
	var skips []skipped
	for _, rt := range roots {
		err := fs.WalkDir(repo, rt.Path, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() || !composeNames[d.Name()] {
				return nil
			}
			f, err := repo.Open(path)
			if err != nil {
				return err
			}
			defer f.Close()
			values, err := imageLines(f)
			if err != nil {
				return fmt.Errorf("%s: %w", path, err)
			}
			place := rt.Host + " " + filepath.Base(filepath.Dir(path))
			for _, v := range values {
				ref, ok := parseImage(v)
				if !ok {
					skips = append(skips, skipped{v, "variable or no tag"})
					continue
				}
				if _, isVer := parseVersion(ref.Tag); !isVer && ref.Digest == "" {
					skips = append(skips, skipped{v, "floating tag without digest"})
					continue
				}
				pins = append(pins, pin{Ref: ref, Place: place})
			}
			return nil
		})
		if err != nil {
			return nil, nil, fmt.Errorf("root %s: %w", rt.Path, err)
		}
	}
	sort.Slice(pins, func(i, j int) bool {
		if pins[i].Ref.String() != pins[j].Ref.String() {
			return pins[i].Ref.String() < pins[j].Ref.String()
		}
		return pins[i].Place < pins[j].Place
	})
	return pins, skips, nil
}
