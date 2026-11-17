package redact

import (
	"encoding/base64"
	"encoding/hex"
	"net/url"
	"sort"
	"strings"
)

// ClassTainted is the class of a text that the taint check removed.
const ClassTainted = "tainted"

// TaintMarker replaces a text that the taint check found.
const TaintMarker = markerPrefix + ClassTainted + "]"

const (
	// MinTaintChars is the shortest value that the taint check looks for.
	// A rule that is not sure also takes short ordinary words, and these
	// words would give too many false hits. Shorter values are a known gap.
	MinTaintChars = 8
	// gramChars is the window for long values: a part of a long value with
	// this length in the output is a hit.
	gramChars = 16
	// The limits keep the memory small for a hostile input with many
	// values. Over a limit, Overflow is true, and the caller must not give
	// raw input to the model.
	maxTaintValues = 2000
	maxTaintChars  = 256 << 10
)

// Taint is the set of the secret values of one call. The model can see
// these values when the config permits raw input. The orchestrator must
// never see them, so Scrub removes them from each text that goes to it.
//
// Scrub finds a value in these forms: exact, in a different letter case,
// with separators between the characters, reversed, base64, hex and URL
// escape. The comparison uses a normal form: ASCII letters and digits only,
// in lower case.
type Taint struct {
	// windows has the normal forms, by length: the full form of a short
	// value, or each window of gramChars of a long value.
	windows map[int]map[string]struct{}
	// literals are the values with a normal form that is too short (many
	// symbols), in ASCII lower case.
	literals []string
	values   map[string]bool
	chars    int
	overflow bool
}

// NewTaint makes an empty set.
func NewTaint() *Taint {
	return &Taint{windows: map[int]map[string]struct{}{}, values: map[string]bool{}}
}

// Overflow is true when the input had more values than the limits permit.
// The set is then not complete.
func (t *Taint) Overflow() bool { return t.overflow }

// Empty is true when the set has no value.
func (t *Taint) Empty() bool { return len(t.values) == 0 }

// Add puts values into the set. A value that is shorter than MinTaintChars
// is ignored.
func (t *Taint) Add(values ...string) {
	for _, value := range values {
		if len(value) < MinTaintChars || t.values[value] {
			continue
		}
		if len(t.values) >= maxTaintValues || t.chars+len(value) > maxTaintChars {
			t.overflow = true
			continue
		}
		t.values[value] = true
		t.chars += len(value)
		for _, form := range forms(value) {
			t.addForm(form)
		}
		if len(normal(value)) < MinTaintChars {
			t.literals = append(t.literals, asciiLower(value))
		}
	}
}

func (t *Taint) addForm(form string) {
	n := normal(form)
	switch {
	case len(n) >= gramChars:
		set := t.windowSet(gramChars)
		for i := 0; i+gramChars <= len(n); i++ {
			set[n[i:i+gramChars]] = struct{}{}
		}
	case len(n) >= MinTaintChars:
		t.windowSet(len(n))[n] = struct{}{}
	}
}

func (t *Taint) windowSet(length int) map[string]struct{} {
	set := t.windows[length]
	if set == nil {
		set = map[string]struct{}{}
		t.windows[length] = set
	}
	return set
}

// forms gives the changed forms of a value that a model can write.
func forms(value string) []string {
	raw := []byte(value)
	out := []string{value, reverse(value), hex.EncodeToString(raw), url.QueryEscape(value)}
	// base64 at the three byte positions. The bytes before the value
	// change only the first characters, and the bytes after it change
	// only the last characters, so the code removes those characters.
	for pad := 0; pad < 3; pad++ {
		enc := strings.TrimRight(base64.StdEncoding.EncodeToString(append(make([]byte, pad), raw...)), "=")
		skip := (pad*8 + 5) / 6
		if len(enc) > skip+3 {
			out = append(out, enc[skip:len(enc)-3])
		}
	}
	return out
}

// Scrub replaces each found value with TaintMarker. It returns the new
// text and the number of replacements.
func (t *Taint) Scrub(text string) (string, int) {
	if t == nil || t.Empty() || text == "" {
		return text, 0
	}
	// pos[i] is the byte offset in text of the character i of the normal
	// form. Only ASCII bytes go into the normal form, so each offset is at
	// the start of a character, and the character has one byte.
	var norm strings.Builder
	pos := make([]int, 0, len(text))
	for i := 0; i < len(text); i++ {
		if c, ok := normalByte(text[i]); ok {
			norm.WriteByte(c)
			pos = append(pos, i)
		}
	}
	n := norm.String()

	var spans []span
	for length, set := range t.windows {
		for i := 0; i+length <= len(n); i++ {
			if _, ok := set[n[i:i+length]]; ok {
				spans = append(spans, span{pos[i], pos[i+length-1] + 1})
			}
		}
	}
	lower := asciiLower(text)
	for _, literal := range t.literals {
		for from := 0; ; {
			i := strings.Index(lower[from:], literal)
			if i < 0 {
				break
			}
			start := from + i
			spans = append(spans, span{start, start + len(literal)})
			from = start + len(literal)
		}
	}
	return replaceSpans(text, spans)
}

type span struct{ start, end int }

// replaceSpans merges the spans that overlap and replaces each one.
func replaceSpans(text string, spans []span) (string, int) {
	if len(spans) == 0 {
		return text, 0
	}
	sort.Slice(spans, func(i, j int) bool { return spans[i].start < spans[j].start })
	merged := []span{spans[0]}
	for _, s := range spans[1:] {
		last := &merged[len(merged)-1]
		if s.start <= last.end {
			last.end = max(last.end, s.end)
			continue
		}
		merged = append(merged, s)
	}
	var out strings.Builder
	out.Grow(len(text))
	prev := 0
	for _, s := range merged {
		out.WriteString(text[prev:s.start])
		out.WriteString(TaintMarker)
		prev = s.end
	}
	out.WriteString(text[prev:])
	return out.String(), len(merged)
}

func normalByte(c byte) (byte, bool) {
	switch {
	case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		return c, true
	case c >= 'A' && c <= 'Z':
		return c + 'a' - 'A', true
	}
	return 0, false
}

func normal(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if c, ok := normalByte(s[i]); ok {
			b.WriteByte(c)
		}
	}
	return b.String()
}

// asciiLower changes only A to Z, so the byte offsets stay the same.
func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

func reverse(s string) string {
	r := []rune(s)
	for i, j := 0, len(r)-1; i < j; i, j = i+1, j-1 {
		r[i], r[j] = r[j], r[i]
	}
	return string(r)
}
