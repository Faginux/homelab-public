// Package localllm has no code. It holds the guard tests that read the
// source of the full module and fail when a change breaks a structural
// safety rule of the plan (layers L1, L2, L6 and L7).
package localllm

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// sourceFile is one Go file of the program. Test files are not included:
// they are not in the binary.
type sourceFile struct {
	path string // with forward slashes, relative to the module root
	ast  *ast.File
}

func loadSources(t *testing.T) []sourceFile {
	t.Helper()
	fset := token.NewFileSet()
	var files []sourceFile
	err := filepath.WalkDir(".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		parsed, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		files = append(files, sourceFile{path: filepath.ToSlash(path), ast: parsed})
		return nil
	})
	if err != nil {
		t.Fatalf("read the sources: %v", err)
	}
	// A wrong folder must not make the guards pass with nothing to read.
	if len(files) < 25 {
		t.Fatalf("found %d source files, want the full module", len(files))
	}
	return files
}

func imports(f sourceFile) []string {
	var paths []string
	for _, spec := range f.ast.Imports {
		path, _ := strconv.Unquote(spec.Path.Value)
		paths = append(paths, path)
	}
	return paths
}

// selectorCalls returns the calls of the form pkg.Name(...) in a file.
func selectorCalls(f sourceFile, pkg string) []*ast.CallExpr {
	var calls []*ast.CallExpr
	ast.Inspect(f.ast, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
			if ident, ok := sel.X.(*ast.Ident); ok && ident.Name == pkg {
				calls = append(calls, call)
			}
		}
		return true
	})
	return calls
}

// L7: the program starts one process only, nvidia-smi, with a constant
// argument list.
func TestOnlyOneProcessStart(t *testing.T) {
	const gpuFile = "internal/gpu/gpu.go"
	var starts int
	for _, f := range loadSources(t) {
		for _, path := range imports(f) {
			if path == "os/exec" && !strings.HasPrefix(f.path, "internal/gpu/") {
				t.Errorf("%s imports os/exec: only internal/gpu can start a process", f.path)
			}
		}
		for _, call := range selectorCalls(f, "exec") {
			name := call.Fun.(*ast.SelectorExpr).Sel.Name
			if name == "LookPath" {
				continue // finds a program, starts nothing
			}
			starts++
			last, isIdent := call.Args[len(call.Args)-1].(*ast.Ident)
			if f.path != gpuFile || name != "CommandContext" || len(call.Args) != 3 ||
				!isIdent || last.Name != "smiArgs" || !call.Ellipsis.IsValid() {
				t.Errorf("%s: exec.%s is not the one permitted call exec.CommandContext(ctx, path, smiArgs...)", f.path, name)
			}
		}
	}
	if starts != 1 {
		t.Errorf("the module has %d process starts, want exactly 1", starts)
	}
}

// The argument list of that one process is a list of string literals.
func TestProcessArgumentsAreLiterals(t *testing.T) {
	var found bool
	for _, f := range loadSources(t) {
		if f.path != "internal/gpu/gpu.go" {
			continue
		}
		ast.Inspect(f.ast, func(n ast.Node) bool {
			spec, ok := n.(*ast.ValueSpec)
			if !ok || len(spec.Names) != 1 || spec.Names[0].Name != "smiArgs" {
				return true
			}
			found = true
			list, ok := spec.Values[0].(*ast.CompositeLit)
			if !ok || len(list.Elts) == 0 {
				t.Error("smiArgs is not a list literal")
				return false
			}
			for _, element := range list.Elts {
				if lit, ok := element.(*ast.BasicLit); !ok || lit.Kind != token.STRING {
					t.Error("an element of smiArgs is not a string literal")
				}
			}
			return false
		})
	}
	if !found {
		t.Error("smiArgs was not found in internal/gpu/gpu.go")
	}
}

// L7 and L2: no other way to start a process, to load code, or to accept a
// network connection.
func TestForbiddenNamesAndImports(t *testing.T) {
	forbiddenNames := map[string]string{
		"StartProcess": "process start", "ForkExec": "process start", "CreateProcess": "process start",
		"CreateProcessAsUser": "process start", "ShellExecute": "process start",
		"CommandTransport": "MCP client that starts a process",
		"NewLazyDLL":       "direct system call", "NewLazySystemDLL": "direct system call",
		"LoadDLL": "direct system call", "MustLoadDLL": "direct system call",
		"Listen": "network listener", "ListenAndServe": "network listener", "ListenAndServeTLS": "network listener",
		"ListenTCP": "network listener", "ListenUDP": "network listener", "ListenPacket": "network listener",
		"ListenConfig": "network listener", "NewStreamableHTTPHandler": "network listener",
		"NewSSEHandler": "network listener", "StreamableHTTPHandler": "network listener", "SSEHandler": "network listener",
	}
	forbiddenImports := map[string]string{
		"unsafe": "memory access with no type check", "plugin": "code load at run time", "C": "cgo",
		"net/http/httptest": "test server", "net/rpc": "network listener",
	}

	for _, f := range loadSources(t) {
		for _, path := range imports(f) {
			if reason, bad := forbiddenImports[path]; bad {
				t.Errorf("%s imports %q (%s)", f.path, path, reason)
			}
			if path == "net/http" && !strings.HasPrefix(f.path, "internal/ollama/") {
				t.Errorf("%s imports net/http: only internal/ollama can make an HTTP request", f.path)
			}
		}
		ast.Inspect(f.ast, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if reason, bad := forbiddenNames[sel.Sel.Name]; bad {
				t.Errorf("%s uses %s (%s)", f.path, sel.Sel.Name, reason)
			}
			return true
		})
	}
}

// L1: the request to the engine has no field for tools.
func TestEngineRequestHasNoTools(t *testing.T) {
	for _, f := range loadSources(t) {
		if !strings.HasPrefix(f.path, "internal/ollama/") {
			continue
		}
		ast.Inspect(f.ast, func(n ast.Node) bool {
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			text := strings.ToLower(lit.Value)
			for _, word := range []string{`"tools"`, `json:"tools`, `json:"tool_`, `"images"`, `json:"images`, `json:"raw`} {
				if strings.Contains(text, word) {
					t.Errorf("%s has the text %s: the engine request must not have this field", f.path, lit.Value)
				}
			}
			return true
		})
	}
}

// L6: the program writes files in two places only, the audit log and the
// staging folder of the drafts.
func TestFileWritesAreInTwoPlaces(t *testing.T) {
	writers := map[string]bool{
		"Create": true, "CreateTemp": true, "OpenFile": true, "WriteFile": true, "Mkdir": true, "MkdirAll": true,
		"MkdirTemp": true, "Remove": true, "RemoveAll": true, "Rename": true, "Link": true, "Symlink": true,
		"Truncate": true, "Chmod": true, "Chown": true, "Chtimes": true, "CopyFS": true,
	}
	want := map[string][]string{
		"internal/audit/audit.go": {"MkdirAll", "OpenFile", "Remove"},
		"internal/tasks/draft.go": {"MkdirAll", "OpenFile"},
	}
	got := map[string][]string{}
	for _, f := range loadSources(t) {
		for _, call := range selectorCalls(f, "os") {
			name := call.Fun.(*ast.SelectorExpr).Sel.Name
			if writers[name] && !contains(got[f.path], name) {
				got[f.path] = append(got[f.path], name)
			}
		}
	}
	for path := range got {
		sort.Strings(got[path])
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("file writes:\n got %v\nwant %v", got, want)
	}
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}
