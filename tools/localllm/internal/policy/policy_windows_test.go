package policy

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

// fixture is a synthetic file tree in a temporary directory:
//
//	base/root      the allowed root
//	base/outside   a folder that is not allowed
type fixture struct {
	root    string
	outside string
	policy  *Policy
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	base := t.TempDir()
	fx := &fixture{
		root:    filepath.Join(base, "root"),
		outside: filepath.Join(base, "outside"),
	}
	for _, dir := range []string{fx.root, fx.outside} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	p, err := New([]string{fx.root}, 4096, 8192)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	fx.policy = p
	return fx
}

func writeFile(t *testing.T, path, content string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	return path
}

// makeJunction makes a directory junction. A junction needs no privilege,
// and it is the link type that the standard library does not resolve. The
// test removes the junction itself, so that the cleanup of the temporary
// directory never goes through it.
func makeJunction(t *testing.T, link, target string) {
	t.Helper()
	out, err := exec.Command("cmd", "/c", "mklink", "/J", link, target).CombinedOutput()
	if err != nil {
		t.Fatalf("mklink /J: %v: %s", err, out)
	}
	t.Cleanup(func() { os.Remove(link) })
}

func shortPath(t *testing.T, path string) string {
	t.Helper()
	from, err := windows.UTF16PtrFromString(path)
	if err != nil {
		t.Fatalf("UTF16PtrFromString: %v", err)
	}
	buf := make([]uint16, 1024)
	n, err := windows.GetShortPathName(from, &buf[0], uint32(len(buf)))
	if err != nil || n == 0 || n >= uint32(len(buf)) {
		t.Skipf("no short path for %s: %v", path, err)
	}
	return windows.UTF16ToString(buf[:n])
}

func TestReadAllowed(t *testing.T) {
	fx := newFixture(t)
	tests := []struct {
		name string
		rel  string
	}{
		{"file in the root", "notes.md"},
		{"file in a subfolder", `logs\app\service.log`},
		{"env example", `stack\.env.example`},
		{"name near a deny rule", "keyboard-layout.txt"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := writeFile(t, filepath.Join(fx.root, tt.rel), "synthetic content\n")
			file, err := fx.policy.Read(path)
			if err != nil {
				t.Fatalf("Read: %v", err)
			}
			if file.Text != "synthetic content\n" {
				t.Errorf("Text = %q", file.Text)
			}
			if file.Name != filepath.Base(tt.rel) {
				t.Errorf("Name = %q, want %q", file.Name, filepath.Base(tt.rel))
			}
			// sha256 of "synthetic content\n"
			if len(file.SHA256) != 64 || file.Bytes != 18 {
				t.Errorf("SHA256 = %q, Bytes = %d", file.SHA256, file.Bytes)
			}
		})
	}
}

func TestReadRefused(t *testing.T) {
	fx := newFixture(t)
	secretOutside := writeFile(t, filepath.Join(fx.outside, "plain.txt"), "outside content\n")
	writeFile(t, filepath.Join(fx.root+"-sibling", "plain.txt"), "sibling content\n")

	tests := []struct {
		name string
		path func(t *testing.T) string
		want string
	}{
		{"outside the roots", func(t *testing.T) string { return secretOutside }, CodeOutsideRoots},
		{"folder name that starts with the root name", func(t *testing.T) string {
			return filepath.Join(fx.root+"-sibling", "plain.txt")
		}, CodeOutsideRoots},
		{"parent traversal", func(t *testing.T) string {
			return fx.root + `\..\outside\plain.txt`
		}, CodeOutsideRoots},
		{"missing file", func(t *testing.T) string { return filepath.Join(fx.root, "missing.txt") }, CodeNotFound},
		{"directory", func(t *testing.T) string {
			dir := filepath.Join(fx.root, "folder")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			return dir
		}, CodeNotRegular},
		{"device name", func(t *testing.T) string { return filepath.Join(fx.root, "NUL") }, CodeOpenFailed},
		{"file above the limit", func(t *testing.T) string {
			return writeFile(t, filepath.Join(fx.root, "big.log"), strings.Repeat("x", 4097))
		}, CodeTooLarge},
		{"binary file", func(t *testing.T) string {
			return writeFile(t, filepath.Join(fx.root, "image.bin"), "\x89PNG\x00\x00data")
		}, CodeBinary},
		{"alternate data stream", func(t *testing.T) string {
			return writeFile(t, filepath.Join(fx.root, "ads.txt"), "x") + ":hidden"
		}, CodeInvalidPath},
		{"relative path", func(t *testing.T) string { return "notes.md" }, CodeInvalidPath},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := tt.path(t)
			file, err := fx.policy.Read(path)
			if got := CodeOf(err); got != tt.want {
				t.Fatalf("Read(%q) code = %q (%v), want %q", path, got, err, tt.want)
			}
			if file != nil {
				t.Error("Read returned a file together with a refusal")
			}
		})
	}
}

func TestReadDeniedNames(t *testing.T) {
	fx := newFixture(t)
	names := []string{
		".env", ".env.production", "stack.env", "server.key", "cert.pem", "id_ed25519",
		"vault.kdbx", "telegram.config.psd1", "prod.tfstate", "keys.txt",
		`.ssh\config`, `.git\config`, `.aws\credentials`, `sub\.docker\config.json`,
	}
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			path := writeFile(t, filepath.Join(fx.root, name), "CANARY-denied-file-content\n")
			_, err := fx.policy.Read(path)
			if got := CodeOf(err); got != CodeDeniedName {
				t.Fatalf("Read(%q) code = %q (%v), want %q", path, got, err, CodeDeniedName)
			}
			if strings.Contains(err.Error(), "CANARY") {
				t.Error("the refusal contains file content")
			}
		})
	}
}

func TestReadDotAtTheEnd(t *testing.T) {
	fx := newFixture(t)
	path := writeFile(t, filepath.Join(fx.root, "server.key"), "synthetic\n")
	// Windows ignores the dot, so this path opens server.key.
	_, err := fx.policy.Read(path + ".")
	if got := CodeOf(err); got != CodeDeniedName {
		t.Errorf("code = %q (%v), want %q", got, err, CodeDeniedName)
	}
}

func TestReadJunctionEscape(t *testing.T) {
	fx := newFixture(t)
	writeFile(t, filepath.Join(fx.outside, "plain.txt"), "outside content\n")
	writeFile(t, filepath.Join(fx.root, "inside", "plain.txt"), "inside content\n")
	writeFile(t, filepath.Join(fx.root, ".ssh", "config"), "synthetic\n")

	makeJunction(t, filepath.Join(fx.root, "to-outside"), fx.outside)
	makeJunction(t, filepath.Join(fx.root, "to-inside"), filepath.Join(fx.root, "inside"))
	makeJunction(t, filepath.Join(fx.root, "to-secret-folder"), filepath.Join(fx.root, ".ssh"))

	tests := []struct {
		name string
		path string
		want string
	}{
		{"junction to a folder outside the roots", filepath.Join(fx.root, "to-outside", "plain.txt"), CodeOutsideRoots},
		{"junction to a folder in the root", filepath.Join(fx.root, "to-inside", "plain.txt"), ""},
		{"junction with a harmless name to a denied folder", filepath.Join(fx.root, "to-secret-folder", "config"), CodeDeniedName},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			file, err := fx.policy.Read(tt.path)
			if got := CodeOf(err); got != tt.want {
				t.Fatalf("Read(%q) code = %q (%v), want %q", tt.path, got, err, tt.want)
			}
			resolved, _ := fx.policy.Roots()
			if tt.want == "" && !isUnder(resolved[0], file.Canonical) {
				t.Errorf("Canonical = %q is not below the root", file.Canonical)
			}
		})
	}
}

func TestReadSymlinkEscape(t *testing.T) {
	fx := newFixture(t)
	target := writeFile(t, filepath.Join(fx.outside, "plain.txt"), "outside content\n")
	link := filepath.Join(fx.root, "link.txt")
	if err := os.Symlink(target, link); err != nil {
		t.Skipf("this account cannot make a symbolic link: %v", err)
	}
	_, err := fx.policy.Read(link)
	if got := CodeOf(err); got != CodeOutsideRoots {
		t.Errorf("code = %q (%v), want %q", got, err, CodeOutsideRoots)
	}
}

func TestReadHardLink(t *testing.T) {
	fx := newFixture(t)
	target := writeFile(t, filepath.Join(fx.outside, "plain.txt"), "outside content\n")
	alias := filepath.Join(fx.root, "alias.txt")
	if err := os.Link(target, alias); err != nil {
		t.Skipf("this volume cannot make a hard link: %v", err)
	}
	_, err := fx.policy.Read(alias)
	if got := CodeOf(err); got != CodeHardLink {
		t.Errorf("code = %q (%v), want %q", got, err, CodeHardLink)
	}
}

func TestReadShortNames(t *testing.T) {
	fx := newFixture(t)
	allowed := writeFile(t, filepath.Join(fx.root, "a long folder name", "a long file name.txt"), "synthetic\n")
	denied := writeFile(t, filepath.Join(fx.root, "a long folder name", ".env.production"), "synthetic\n")

	shortAllowed := shortPath(t, allowed)
	shortDenied := shortPath(t, denied)
	if strings.EqualFold(shortAllowed, allowed) {
		t.Skip("this volume has no short names")
	}

	t.Run("short path of an allowed file", func(t *testing.T) {
		file, err := fx.policy.Read(shortAllowed)
		if err != nil {
			t.Fatalf("Read(%q): %v", shortAllowed, err)
		}
		if file.Name != "a long file name.txt" {
			t.Errorf("Name = %q, want the long name", file.Name)
		}
	})
	t.Run("short path hides a denied name", func(t *testing.T) {
		if deniedPath(shortDenied) != "" {
			t.Skipf("the short path %q still shows the denied name", shortDenied)
		}
		_, err := fx.policy.Read(shortDenied)
		if got := CodeOf(err); got != CodeDeniedName {
			t.Errorf("Read(%q) code = %q (%v), want %q", shortDenied, got, err, CodeDeniedName)
		}
	})
	t.Run("root given as a short path", func(t *testing.T) {
		p, err := New([]string{shortPath(t, fx.root)}, 4096, 8192)
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		if _, err := p.Read(allowed); err != nil {
			t.Errorf("Read with a short root: %v", err)
		}
	})
}

func TestReadAll(t *testing.T) {
	fx := newFixture(t)
	a := writeFile(t, filepath.Join(fx.root, "a.log"), strings.Repeat("a", 4000))
	b := writeFile(t, filepath.Join(fx.root, "b.log"), strings.Repeat("b", 4000))
	c := writeFile(t, filepath.Join(fx.root, "c.log"), strings.Repeat("c", 4000))
	outside := writeFile(t, filepath.Join(fx.outside, "plain.txt"), "outside\n")

	tests := []struct {
		name  string
		paths []string
		want  string
	}{
		{"two files in the call limit", []string{a, b}, ""},
		{"three files above the call limit", []string{a, b, c}, CodeCallTooLarge},
		{"one refusal refuses the call", []string{a, outside}, CodeOutsideRoots},
		{"too many files", make([]string, MaxFilesPerCall+1), CodeTooManyFiles},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			files, err := fx.policy.ReadAll(tt.paths)
			if got := CodeOf(err); got != tt.want {
				t.Fatalf("ReadAll code = %q (%v), want %q", got, err, tt.want)
			}
			if tt.want == "" && len(files) != len(tt.paths) {
				t.Errorf("ReadAll returned %d files, want %d", len(files), len(tt.paths))
			}
			if tt.want != "" && files != nil {
				t.Error("ReadAll returned files together with a refusal")
			}
		})
	}
}

func TestNewRefusesBadRoots(t *testing.T) {
	tests := []struct {
		name  string
		roots []string
	}{
		{"no roots", nil},
		{"relative root", []string{"relative"}},
		{"UNC root", []string{`\\localhost\C$`}},
		{"one bad root in the list", []string{`C:\data`, `..\other`}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := New(tt.roots, 4096, 8192); err == nil {
				t.Error("New accepted the roots, want an error")
			}
		})
	}
}

// A temporary folder can be missing when the program starts. Such a root
// permits nothing until it exists.
func TestRootThatDoesNotExistYet(t *testing.T) {
	base := t.TempDir()
	late := filepath.Join(base, "late")
	fileRoot := writeFile(t, filepath.Join(base, "file-as-root"), "x")
	other := writeFile(t, filepath.Join(base, "other", "plain.txt"), "synthetic\n")

	p, err := New([]string{late, fileRoot}, 4096, 8192)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := p.Read(other); CodeOf(err) != CodeOutsideRoots {
		t.Errorf("code = %q (%v), want %q while no root exists", CodeOf(err), err, CodeOutsideRoots)
	}
	if resolved, missing := p.Roots(); len(resolved) != 0 || len(missing) != 2 {
		t.Errorf("Roots = %v, %v, want no resolved root and two missing roots", resolved, missing)
	}

	inLate := writeFile(t, filepath.Join(late, "plain.txt"), "synthetic\n")
	if _, err := p.Read(inLate); err != nil {
		t.Errorf("Read after the root exists: %v", err)
	}
	if resolved, missing := p.Roots(); len(resolved) != 1 || len(missing) != 1 {
		t.Errorf("Roots = %v, %v, want one resolved root and one missing root", resolved, missing)
	}
}
