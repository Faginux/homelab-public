package policy

import "testing"

func TestDeniedComponent(t *testing.T) {
	tests := []struct {
		name   string
		denied bool
	}{
		{".env", true},
		{".ENV", true},
		{".env.local", true},
		{".env.example.bak", true},
		{".envrc", true},
		{"stack.env", true},
		{"server.key", true},
		{"SERVER.KEY", true},
		{"server.key.", true},
		{"server.key ", true},
		{"cert.pem", true},
		{"id_ed25519", true},
		{"id_rsa.pub", true},
		{"vault.kdbx", true},
		{"backup.pfx", true},
		{"store.p12", true},
		{"putty.ppk", true},
		{"prod.tfstate", true},
		{"telegram.config.psd1", true},
		{"Telegram.Config.psd1", true},
		{"keys.txt", true},
		{".ssh", true},
		{".git", true},
		{".aws", true},
		{".kube", true},
		{".docker", true},
		{".gnupg", true},
		{".netrc", true},
		{"_netrc", true},
		{".git-credentials", true},
		{".npmrc", true},
		{".pgpass", true},

		{".env.example", false},
		{".ENV.EXAMPLE", false},
		{".gitignore", false},
		{".github", false},
		{"keyboard.txt", false},
		{"monkey.md", false},
		{"environment.md", false},
		{"docker-compose.yml", false},
		{"valid_id.txt", false},
		{"README.md", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rule := deniedComponent(tt.name)
			if (rule != "") != tt.denied {
				t.Errorf("deniedComponent(%q) = %q, want denied = %v", tt.name, rule, tt.denied)
			}
		})
	}
}

func TestCheckRequested(t *testing.T) {
	tests := []struct {
		name string
		path string
		want string
	}{
		{"drive absolute", `C:\data\notes.md`, ""},
		{"forward slashes", `C:/data/notes.md`, ""},
		{"env example", `C:\data\stack\.env.example`, ""},
		{"empty", ``, CodeInvalidPath},
		{"relative", `notes.md`, CodeInvalidPath},
		{"relative with parent", `..\notes.md`, CodeInvalidPath},
		{"drive relative", `C:notes.md`, CodeInvalidPath},
		{"rooted without drive", `\data\notes.md`, CodeInvalidPath},
		{"UNC", `\\localhost\C$\data\notes.md`, CodeInvalidPath},
		{"extended prefix", `\\?\C:\data\notes.md`, CodeInvalidPath},
		{"device namespace", `\\.\C:\data\notes.md`, CodeInvalidPath},
		{"alternate data stream", `C:\data\notes.md:hidden`, CodeInvalidPath},
		{"default data stream", `C:\data\server.txt::$DATA`, CodeInvalidPath},
		{"wildcard", `C:\data\*.md`, CodeInvalidPath},
		{"NUL character", "C:\\data\\a\x00b", CodeInvalidPath},
		{"secret file", `C:\data\stack\.env`, CodeDeniedName},
		{"secret directory", `C:\data\profile\.ssh\config`, CodeDeniedName},
		{"secret directory in the middle", `C:\data\repo\.git\config`, CodeDeniedName},
		{"dot at the end", `C:\data\server.key.`, CodeDeniedName},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := CodeOf(checkRequested(tt.path))
			if got != tt.want {
				t.Errorf("checkRequested(%q) code = %q, want %q", tt.path, got, tt.want)
			}
		})
	}
}

func TestIsUnder(t *testing.T) {
	tests := []struct {
		name       string
		root, path string
		want       bool
	}{
		{"file in the root", `C:\data`, `C:\data\notes.md`, true},
		{"file in a subfolder", `C:\data`, `C:\data\a\b\notes.md`, true},
		{"case does not matter", `C:\Data`, `c:\DATA\notes.md`, true},
		{"root with a separator at the end", `C:\data\`, `C:\data\notes.md`, true},
		{"the root itself", `C:\data`, `C:\data`, false},
		{"name that starts with the root name", `C:\data`, `C:\data-other\notes.md`, false},
		{"parent of the root", `C:\data\sub`, `C:\data\notes.md`, false},
		{"different drive", `C:\data`, `D:\data\notes.md`, false},
		{"empty root", ``, `C:\data\notes.md`, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isUnder(tt.root, tt.path); got != tt.want {
				t.Errorf("isUnder(%q, %q) = %v, want %v", tt.root, tt.path, got, tt.want)
			}
		})
	}
}

func TestText(t *testing.T) {
	tests := []struct {
		name     string
		data     []byte
		want     string
		wantCode string
	}{
		{"plain text", []byte("line one\nline two\r\n"), "line one\nline two\r\n", ""},
		{"UTF-8 text", []byte("caffè è pronto"), "caffè è pronto", ""},
		{"byte order mark", []byte("\xEF\xBB\xBFtext"), "text", ""},
		{"ANSI color codes", []byte("\x1b[31merror\x1b[0m in the service"), "\x1b[31merror\x1b[0m in the service", ""},
		{"one byte of an old code page", []byte("il servizio non \xE8 partito, controllare il log"), "il servizio non \uFFFD partito, controllare il log", ""},
		{"empty", []byte{}, "", ""},
		{"NUL byte", []byte("text\x00text"), "", CodeBinary},
		{"UTF-16", []byte("\xFF\xFEt\x00e\x00x\x00t\x00"), "", CodeBinary},
		{"random bytes with no NUL", []byte{0x8f, 0x91, 0xfe, 0x03, 0x99, 0xa1, 0x07, 0xc5, 0x10, 0xee}, "", CodeBinary},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Text(tt.data)
			if code := CodeOf(err); code != tt.wantCode {
				t.Fatalf("Text code = %q (%v), want %q", code, err, tt.wantCode)
			}
			if got != tt.want {
				t.Errorf("Text = %q, want %q", got, tt.want)
			}
		})
	}
}
