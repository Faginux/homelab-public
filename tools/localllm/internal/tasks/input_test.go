package tasks

import (
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSplitChunks(t *testing.T) {
	tests := []struct {
		name      string
		text      string
		max       int
		wantParts int
	}{
		{"short text", "one line\n", 100, 1},
		{"empty text", "", 100, 1},
		{"exactly the limit", strings.Repeat("a", 99) + "\n", 100, 1},
		{"two lines above the limit", strings.Repeat("a", 60) + "\n" + strings.Repeat("b", 60) + "\n", 100, 2},
		{"cut at line ends", strings.Repeat("line of text\n", 20), 100, 3},
		{"one line longer than the limit", strings.Repeat("x", 250), 100, 3},
		{"long line between short lines", "short\n" + strings.Repeat("x", 250) + "\nshort\n", 100, 4},
		{"characters of more than one byte", strings.Repeat("è", 120), 100, 3},
		{"no line end at the end", "first\nsecond", 100, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parts := splitChunks(tt.text, tt.max)
			if len(parts) != tt.wantParts {
				t.Errorf("parts = %d, want %d", len(parts), tt.wantParts)
			}
			if joined := strings.Join(parts, ""); joined != tt.text {
				t.Errorf("the parts do not give the input again:\n got %q\nwant %q", joined, tt.text)
			}
			for i, part := range parts {
				if len(part) > tt.max {
					t.Errorf("part %d has %d bytes, limit %d", i, len(part), tt.max)
				}
				if !utf8.ValidString(part) {
					t.Errorf("part %d cuts a character", i)
				}
			}
		})
	}
}

func TestNumberedChunks(t *testing.T) {
	var lines []string
	for i := 1; i <= 50; i++ {
		lines = append(lines, fmt.Sprintf("entry number %d", i))
	}
	lines[20] = strings.Repeat("y", 2000) // one long line

	chunks := numberedChunks(3, lines, 400)
	if len(chunks) < 3 {
		t.Fatalf("chunks = %d, want 3 or more", len(chunks))
	}
	next := 1
	for i, ch := range chunks {
		if ch.doc != 3 || ch.part != i+1 || ch.parts != len(chunks) {
			t.Errorf("chunk %d: doc = %d, part = %d of %d", i, ch.doc, ch.part, ch.parts)
		}
		if ch.firstLine != next {
			t.Errorf("chunk %d starts at line %d, want %d", i, ch.firstLine, next)
		}
		got := strings.Split(strings.TrimRight(ch.text, "\n"), "\n")
		if len(got) != ch.lastLine-ch.firstLine+1 {
			t.Errorf("chunk %d has %d lines for the range %d to %d", i, len(got), ch.firstLine, ch.lastLine)
		}
		for n, line := range got {
			if !strings.HasPrefix(line, fmt.Sprintf("%d| ", ch.firstLine+n)) {
				t.Errorf("chunk %d line %d has no number: %q", i, n, line[:min(len(line), 20)])
			}
		}
		next = ch.lastLine + 1
	}
	if next != 51 {
		t.Errorf("the chunks end at line %d, want 50", next-1)
	}
	for _, ch := range chunks {
		if strings.Contains(ch.text, strings.Repeat("y", maxLogLineChars+1)) {
			t.Error("a long line was not cut")
		}
	}
}

func TestClip(t *testing.T) {
	tests := []struct {
		name    string
		text    string
		max     int
		want    string
		wantCut bool
	}{
		{"shorter than the limit", "abc", 5, "abc", false},
		{"exactly the limit", "abcde", 5, "abcde", false},
		{"longer than the limit", "abcdefgh", 5, "abcde", true},
		{"characters of more than one byte", "èèèèèèè", 3, "èèè", true},
		{"empty", "", 5, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, cut := clip(tt.text, tt.max)
			if got != tt.want || cut != tt.wantCut {
				t.Errorf("clip(%q, %d) = %q, %v, want %q, %v", tt.text, tt.max, got, cut, tt.want, tt.wantCut)
			}
		})
	}
	if got := clipMark("  abcdefgh  ", 5); got != "abcde…" {
		t.Errorf("clipMark = %q, want %q", got, "abcde…")
	}
}
