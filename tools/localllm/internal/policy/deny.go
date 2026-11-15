package policy

import (
	"regexp"
	"strings"
)

// The deny list is the second control, after the allowed roots. It stops the
// usual homes of secrets also when they are in an allowed root.
var (
	deniedExact = map[string]bool{
		".ssh": true, ".gnupg": true, ".aws": true, ".kube": true, ".docker": true,
		// .git/config can contain a credential in a remote URL.
		".git":   true,
		".netrc": true, "_netrc": true, ".git-credentials": true, ".npmrc": true, ".pgpass": true,
		"telegram.config.psd1": true,
		// The usual names of an age identity file.
		"keys.txt": true, "key.txt": true,
	}
	deniedPrefix = []string{".env", "id_"}
	deniedSuffix = []string{".env", ".key", ".pem", ".kdbx", ".pfx", ".p12", ".ppk", ".tfstate", ".agekey"}
)

// envExample is the only name with the prefix ".env" that the policy permits.
const envExample = ".env.example"

var driveAbsolute = regexp.MustCompile(`^[A-Za-z]:[\\/]`)

// checkRequested examines the path text before the file is opened. It
// permits only a drive-absolute path, so UNC paths, device namespaces and
// relative paths are refused. It also refuses a known secret name, so that
// the file is not opened at all.
func checkRequested(path string) error {
	switch {
	case path == "":
		return deny(CodeInvalidPath, path, "the path is empty")
	case strings.ContainsAny(path, "\x00*?<>|\""):
		return deny(CodeInvalidPath, path, "the path has a character that is not permitted")
	case !driveAbsolute.MatchString(path):
		return deny(CodeInvalidPath, path, "only a drive-absolute path is permitted, for example C:\\dir\\file.txt")
	case strings.Contains(path[2:], ":"):
		// A second colon selects an alternate data stream of the file.
		return deny(CodeInvalidPath, path, "alternate data streams are not permitted")
	}
	if rule := deniedPath(path); rule != "" {
		return deny(CodeDeniedName, path, "the name agrees with the deny rule "+rule)
	}
	return nil
}

// deniedPath returns the deny rule that agrees with a component of the path,
// or an empty string.
func deniedPath(path string) string {
	for _, component := range splitPath(path) {
		if rule := deniedComponent(component); rule != "" {
			return rule
		}
	}
	return ""
}

func deniedComponent(component string) string {
	name := normalizeComponent(component)
	if name == envExample {
		return ""
	}
	if deniedExact[name] {
		return name
	}
	for _, prefix := range deniedPrefix {
		if strings.HasPrefix(name, prefix) {
			return prefix + "*"
		}
	}
	for _, suffix := range deniedSuffix {
		if strings.HasSuffix(name, suffix) {
			return "*" + suffix
		}
	}
	return ""
}

// normalizeComponent gives the name as Windows opens it: case does not
// matter, and dots and spaces at the end are ignored.
func normalizeComponent(component string) string {
	return strings.ToLower(strings.TrimRight(component, ". "))
}

func splitPath(path string) []string {
	return strings.FieldsFunc(path, func(r rune) bool { return r == '\\' || r == '/' })
}

// isUnder reports if path is below root. It compares full components, so
// the root C:\data does not contain C:\data-other.
func isUnder(root, path string) bool {
	rootParts := splitPath(root)
	pathParts := splitPath(path)
	if len(rootParts) == 0 || len(pathParts) <= len(rootParts) {
		return false
	}
	for i, part := range rootParts {
		if !strings.EqualFold(part, pathParts[i]) {
			return false
		}
	}
	return true
}
