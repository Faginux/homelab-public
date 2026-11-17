// Package redact removes secrets from text (layer L4 of the plan). The
// secret boundary is the orchestrator: no secret may reach it. The rules
// always run on the model output. They run on the model input unless the
// config permits raw input. Taint (taint.go) finds the secret values of the
// input in the output, also in a changed form.
//
// The aim is to prevent accidents: a secret in a log or in a config file
// must not go into a result, a draft or an audit record. The rules know the
// usual formats only. A secret in an unknown format passes, so the path
// policy stays the first control. When a rule is not sure, it removes more
// text, not less.
//
// All rules use the regexp package of the standard library. Its matching
// time is linear in the input size, so a hostile log line cannot make a
// rule slow.
package redact

import (
	"regexp"
	"strings"
)

const markerPrefix = "[REDACTED:"

// Class names of the rules. The audit log counts the replacements per class.
const (
	ClassPEM          = "pem"
	ClassJWT          = "jwt"
	ClassAgeKey       = "age_key"
	ClassGitHubToken  = "github_token"
	ClassTelegramBot  = "telegram_bot_token"
	ClassTailscaleKey = "tailscale_key"
	ClassPasswordHash = "password_hash"
	ClassAuthHeader   = "auth_header"
	ClassBearer       = "bearer"
	ClassURLUserinfo  = "url_userinfo"
	ClassKeyValue     = "key_value"
	ClassCLIFlag      = "cli_flag"
)

// name is an identifier that contains one of the words of a secret name.
const name = `[A-Za-z0-9_.-]*(?:pass|secret|key|token|mail|admin|pwd|cred)[A-Za-z0-9_.-]*`

// rule replaces one capture group of each match with a marker. Group 0 is
// the full match.
type rule struct {
	class string
	re    *regexp.Regexp
	group int
}

// The sequence matters. The rules for a specific token format run first, so
// the marker shows the real class. The general rules for name and value run
// last and skip a value that is already a marker.
var rules = []rule{
	{ClassPEM, regexp.MustCompile(`-----BEGIN [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-----`), 0},
	// A block with no END line, for example in a log line that was cut.
	{ClassPEM, regexp.MustCompile(`-----BEGIN [A-Z0-9 ]*PRIVATE KEY[A-Z ]*-----[A-Za-z0-9+/=\s\\]*`), 0},
	{ClassJWT, regexp.MustCompile(`eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*`), 0},
	{ClassAgeKey, regexp.MustCompile(`AGE-SECRET-KEY-1[A-Za-z0-9]+`), 0},
	{ClassGitHubToken, regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}`), 0},
	// No word boundary on the left: in an API URL the token follows the
	// letters "bot" directly.
	{ClassTelegramBot, regexp.MustCompile(`[0-9]{8,10}:[A-Za-z0-9_-]{35,}`), 0},
	{ClassTailscaleKey, regexp.MustCompile(`tskey-[a-z]+-[A-Za-z0-9-]{10,}`), 0},
	// crypt-style hashes (htpasswd, bcrypt, argon2). A compose file writes
	// each dollar sign two times.
	{ClassPasswordHash, regexp.MustCompile(`\${1,2}(?:apr1|2[aby]|5|6|argon2(?:id|i|d))\${1,2}[A-Za-z0-9./$=,+-]{8,}`), 0},

	{ClassAuthHeader, regexp.MustCompile(`(?i)(\bauthorization\\?["']?[ \t]*[:=][ \t]*\\?["']?(?:(?:bearer|basic|token|digest)[ \t]+)?)([^\s"'\\,;]+)`), 2},
	{ClassBearer, regexp.MustCompile(`(?i)(\bbearer[ \t]+)([A-Za-z0-9._~+/=-]{20,})`), 2},
	{ClassURLUserinfo, regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]+:)([^\s/@]+)(@)`), 2},

	// JSON inside a JSON string: the quotes have a backslash.
	{ClassKeyValue, regexp.MustCompile(`(?i)(` + name + `\\"[ \t]*[:=][ \t]*\\")([^"\\\r\n]+)(\\")`), 2},
	{ClassKeyValue, regexp.MustCompile(`(?i)(` + name + `["']?[ \t]*[:=][ \t]*")((?:[^"\\\r\n]|\\.)+)(")`), 2},
	{ClassKeyValue, regexp.MustCompile(`(?i)(` + name + `["']?[ \t]*[:=][ \t]*')([^'\r\n]+)(')`), 2},
	{ClassCLIFlag, regexp.MustCompile(`(?i)(--` + name + `[ \t]+)("[^"\r\n]*"|'[^'\r\n]*'|[^\s"'-]\S*)`), 2},
	// An assignment at the start of a line (env file, compose list, YAML):
	// the value can contain spaces, so the rule removes the rest of the line.
	{ClassKeyValue, regexp.MustCompile(`(?im)^([ \t]*(?:[-*][ \t]+|export[ \t]+|set[ \t]+|\$env:)?["']?` + name + `["']?[ \t]*(?:=[ \t]*|:[ \t]+))([^\s"'\[{][^\r\n]*)`), 2},
	// A pair in the middle of a line (log fields, URL query). A colon with
	// no space is not a pair here: "image:tag" and "host:port" use it too.
	// A value that starts a list or a map is structure, not a secret.
	{ClassKeyValue, regexp.MustCompile(`(?i)(` + name + `(?:["']?[ \t]*=[ \t]*|["'][ \t]*:[ \t]*|:[ \t]+))([^\s"'&,;\[{][^\s"'&,;]*)`), 2},
}

// Result is the redacted text and the number of replacements per class.
type Result struct {
	Text   string
	Counts map[string]int
	// Values are the texts that the rules replaced. They stay in memory for
	// the taint check. Never write them to a log or a result.
	Values []string
}

// Total returns the number of replacements of all classes.
func (r Result) Total() int {
	total := 0
	for _, n := range r.Counts {
		total += n
	}
	return total
}

// Apply runs all rules on the text.
func Apply(text string) Result {
	result := Result{Text: text, Counts: map[string]int{}}
	for _, r := range rules {
		var n int
		result.Text, n = r.apply(result.Text, &result.Values)
		if n > 0 {
			result.Counts[r.class] += n
		}
	}
	return result
}

// apply replaces the matches and adds the replaced texts to values. The
// marker of an earlier rule is not a secret, so the code cuts a value at
// each marker.
func (r rule) apply(text string, values *[]string) (string, int) {
	matches := r.re.FindAllStringSubmatchIndex(text, -1)
	if len(matches) == 0 {
		return text, 0
	}
	var out strings.Builder
	out.Grow(len(text))
	last, count := 0, 0
	for _, m := range matches {
		start, end := m[2*r.group], m[2*r.group+1]
		if start < 0 || strings.HasPrefix(text[start:end], markerPrefix) {
			continue
		}
		*values = append(*values, withoutMarkers(text[start:end])...)
		out.WriteString(text[last:start])
		out.WriteString(markerPrefix + r.class + "]")
		last = end
		count++
	}
	out.WriteString(text[last:])
	return out.String(), count
}

var markerPattern = regexp.MustCompile(`\[REDACTED:[a-z_]+\]`)

func withoutMarkers(value string) []string {
	var parts []string
	for _, part := range markerPattern.Split(value, -1) {
		if part = strings.TrimSpace(part); part != "" {
			parts = append(parts, part)
		}
	}
	return parts
}

// MergeCounts adds the counts of src to dst and returns dst.
func MergeCounts(dst, src map[string]int) map[string]int {
	if dst == nil {
		dst = map[string]int{}
	}
	for class, n := range src {
		dst[class] += n
	}
	return dst
}
