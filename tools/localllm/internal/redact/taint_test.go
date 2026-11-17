package redact

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"
	"testing"
)

func spaced(s, separator string) string { return strings.Join(strings.Split(s, ""), separator) }

func TestApplyKeepsTheReplacedValues(t *testing.T) {
	plain := "Abcdefgh1"
	res := Apply("password = " + plain + " " + canaryJWT + "\nX-Api-Key: " + canaryValue)

	want := map[string]bool{canaryJWT: false, plain: false, canaryValue: false}
	for _, v := range res.Values {
		if strings.Contains(v, markerPrefix) {
			t.Errorf("a value has a marker: %q", v)
		}
		if _, ok := want[v]; ok {
			want[v] = true
		}
	}
	for v, found := range want {
		if !found {
			t.Errorf("the values do not have %q: %q", v, res.Values)
		}
	}
}

func TestTaintScrub(t *testing.T) {
	value := "Cnry" + rep("Q7x", 6) + "Zk"
	symbolic := "!@" + "#$%^" + "&*()" + "x1"
	short := "Ab3" + "d5"
	taint := NewTaint()
	taint.Add(value, symbolic, short)

	b64 := func(prefix string) string {
		return base64.StdEncoding.EncodeToString([]byte(prefix + value + " end"))
	}
	tests := []struct {
		name string
		text string
		hit  bool
		keep []string
	}{
		{"exact", "the value is " + value + " here", true, []string{"the value is ", " here"}},
		{"upper case", strings.ToUpper(value), true, nil},
		{"spaces between the characters", spaced(value, " "), true, nil},
		{"one character for each line", spaced(value, "\n"), true, nil},
		{"hyphens", "x " + spaced(value, "-") + " y", true, []string{"x ", " y"}},
		{"reversed", reverse(value), true, nil},
		{"base64 at byte position 0", b64(""), true, nil},
		{"base64 at byte position 1", b64("x"), true, nil},
		{"base64 at byte position 2", b64("k="), true, nil},
		{"hex", hex.EncodeToString([]byte(value)), true, nil},
		{"hex in upper case", strings.ToUpper(hex.EncodeToString([]byte(value))), true, nil},
		{"a part of 16 characters", value[3:19], true, nil},
		{"value with many symbols, other case", "use " + strings.ToUpper(symbolic) + " now", true, []string{"use ", " now"}},
		{"value with many symbols, URL escape", "q=" + url.QueryEscape(symbolic), true, nil},
		{"short value is ignored", "code " + short, false, nil},
		{"ordinary text", "the service started at 10:05 and the database answered", false, nil},
		{"text with no ASCII letters", "Привет, мир 漢字", false, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, n := taint.Scrub(tt.text)
			if tt.hit != (n > 0) {
				t.Fatalf("replacements = %d, want a hit = %v: %q", n, tt.hit, got)
			}
			if !tt.hit && got != tt.text {
				t.Errorf("the text changed with no hit: %q", got)
			}
			if tt.hit && !strings.Contains(got, TaintMarker) {
				t.Errorf("no marker: %q", got)
			}
			for _, k := range tt.keep {
				if !strings.Contains(got, k) {
					t.Errorf("the text %q is missing from %q", k, got)
				}
			}
			if strings.Contains(normal(got), normal(value)[:gramChars]) {
				t.Errorf("a part of the value is still in %q", got)
			}
		})
	}
}

func TestTaintMergesOverlappingHits(t *testing.T) {
	value := "Mrg" + rep("w9", 15)
	taint := NewTaint()
	taint.Add(value)
	got, n := taint.Scrub("a " + value + " b")
	if n != 1 || got != "a "+TaintMarker+" b" {
		t.Errorf("got %q with %d replacements, want one marker", got, n)
	}
}

func TestTaintOverflow(t *testing.T) {
	taint := NewTaint()
	for i := 0; i <= maxTaintValues; i++ {
		taint.Add(fmt.Sprintf("value-%08d", i))
	}
	if !taint.Overflow() {
		t.Error("the set has more values than the limit, but Overflow is false")
	}

	big := NewTaint()
	big.Add(rep("a", maxTaintChars+1))
	if !big.Overflow() {
		t.Error("the value is larger than the limit, but Overflow is false")
	}
}

func TestEmptyTaintChangesNothing(t *testing.T) {
	var nilTaint *Taint
	for _, taint := range []*Taint{nilTaint, NewTaint()} {
		if got, n := taint.Scrub("some text"); got != "some text" || n != 0 {
			t.Errorf("got %q with %d replacements", got, n)
		}
	}
}
