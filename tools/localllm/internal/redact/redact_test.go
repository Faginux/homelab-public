package redact

import (
	"strings"
	"testing"
)

// The canary values are synthetic. The code builds each one at run time
// from short parts, so that this file has no text with the shape of a real
// token. Secret scanners examine this repository.

func rep(s string, n int) string { return strings.Repeat(s, n) }

func pemBlock(kind, separator string) string {
	begin := "-----BEGIN " + kind + "PRIVATE " + "KEY-----"
	end := "-----END " + kind + "PRIVATE " + "KEY-----"
	return begin + separator + rep("CANARYpem", 6) + separator + rep("Zm9v", 10) + separator + end
}

var (
	canaryJWT      = "eyJ" + rep("h", 20) + "." + "eyJ" + rep("p", 30) + "." + rep("s", 43)
	canaryAge      = "AGE-SECRET-" + "KEY-1" + rep("Q", 58)
	canaryGhp      = "gh" + "p_" + rep("G", 36)
	canaryPat      = "github_" + "pat_" + rep("P", 22) + "_" + rep("p", 59)
	canaryTelegram = "1234567" + "890:" + rep("T", 35)
	canaryTskey    = "ts" + "key-auth-" + rep("k", 12) + "-" + rep("K", 32)
	canaryHash     = "apr1$" + rep("s", 8) + "$" + rep("H", 22)
	canaryValue    = "CANARY" + rep("v", 14)
)

func TestApplyRemovesCanaries(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		canary string
		class  string
		keeps  []string
	}{
		{"PEM block", "before\n" + pemBlock("RSA ", "\n") + "\nafter", "CANARYpem", ClassPEM, []string{"before", "after"}},
		{"OpenSSH PEM block", pemBlock("OPENSSH ", "\n"), "CANARYpem", ClassPEM, nil},
		{"PEM block with no type", pemBlock("", "\r\n"), "CANARYpem", ClassPEM, nil},
		{"PEM block in a JSON string", `{"key_file":"x","data":"` + pemBlock("EC ", `\n`) + `","msg":"loaded"}`, "CANARYpem", ClassPEM, []string{`"msg":"loaded"`}},
		{"PEM block that was cut", "start -----BEGIN " + "PRIVATE " + "KEY-----\n" + rep("CANARYpem", 5), "CANARYpem", ClassPEM, []string{"start"}},
		{"JWT", "session " + canaryJWT + " accepted", canaryJWT, ClassJWT, []string{"session", "accepted"}},
		{"age identity", "# created\n" + canaryAge + "\n", canaryAge, ClassAgeKey, []string{"# created"}},
		{"GitHub classic token", "remote: https://x-access:" + canaryGhp + "@github.example/repo.git", canaryGhp, ClassGitHubToken, nil},
		{"GitHub fine-grained token", "use " + canaryPat + " for the API", canaryPat, ClassGitHubToken, []string{"for the API"}},
		{"Telegram token", "bot id " + canaryTelegram + " started", canaryTelegram, ClassTelegramBot, []string{"started"}},
		{"Telegram token in an API URL", "POST https://api.telegram.example/bot" + canaryTelegram + "/sendMessage 200", canaryTelegram, ClassTelegramBot, []string{"/sendMessage 200"}},
		{"Tailscale key", "tailscale up --authkey=" + canaryTskey, canaryTskey, ClassTailscaleKey, []string{"tailscale up"}},
		{"htpasswd hash", "users=operator:$" + canaryHash + " realm=lab", canaryHash, ClassPasswordHash, []string{"realm=lab"}},
		{"htpasswd hash in a compose label", "- basicauth.users=operator:$$" + strings.ReplaceAll(canaryHash, "$", "$$"), rep("H", 22), ClassPasswordHash, []string{"basicauth.users=operator:"}},

		{"Authorization header with Bearer", "Authorization: Bearer " + canaryValue + "\nAccept: */*", canaryValue, ClassAuthHeader, []string{"Accept: */*"}},
		{"Authorization header with Basic", "Authorization: Basic " + canaryValue, canaryValue, ClassAuthHeader, nil},
		{"Authorization header with no scheme", `"Authorization": "` + canaryValue + `", "Host": "example"`, canaryValue, ClassAuthHeader, []string{`"Host": "example"`}},
		{"Bearer token in a log line", "sent header bearer " + canaryValue + rep("w", 10) + " to upstream", canaryValue, ClassBearer, []string{"to upstream"}},
		{"password in a URL", "DATABASE=postgres://app:" + canaryValue + "@db.example:5432/app", canaryValue, ClassURLUserinfo, []string{"@db.example:5432/app"}},

		{"apikey in a URL query", "GET http://sonarr.example:8989/api/v3/series?apikey=" + canaryValue + "&page=2 200", canaryValue, ClassKeyValue, []string{"&page=2 200", "/api/v3/series"}},
		{"Plex token in a URL query", "GET /library/sections?X-Plex-Token=" + canaryValue + "&type=1", canaryValue, ClassKeyValue, []string{"&type=1"}},
		{"API key header", "X-Api-Key: " + canaryValue, canaryValue, ClassKeyValue, nil},
		{"env file line with spaces in the value", "POSTGRES_PASSWORD=" + canaryValue + " second word\nPOSTGRES_DB=app", "second word", ClassKeyValue, []string{"POSTGRES_DB=app"}},
		{"compose environment list", "    environment:\n      - API_KEY=" + canaryValue + "\n      - TZ=Europe/Rome", canaryValue, ClassKeyValue, []string{"TZ=Europe/Rome", "environment:"}},
		{"YAML mapping", "smtp:\n  password: " + canaryValue + "\n  port: 587", canaryValue, ClassKeyValue, []string{"port: 587", "smtp:"}},
		{"JSON log line", `{"level":"info","api_key":"` + canaryValue + `","msg":"started"}`, canaryValue, ClassKeyValue, []string{`"level":"info"`, `"msg":"started"`}},
		{"JSON in a JSON string", `{"body":"{\"password\":\"` + canaryValue + `\",\"user\":\"operator\"}"}`, canaryValue, ClassKeyValue, []string{`\"user\":\"operator\"`}},
		{"JSON value with an escaped quote", `{"secret":"` + canaryValue + `\"tail","next":1}`, canaryValue, ClassKeyValue, []string{`"next":1`}},
		{"PowerShell data file", "@{\n    BotToken = '" + canaryValue + "'\n    ChatId = 42\n}", canaryValue, ClassKeyValue, []string{"ChatId = 42"}},
		{"PowerShell environment variable", `$env:API_TOKEN = "` + canaryValue + `"`, canaryValue, ClassKeyValue, nil},
		{"shell export", "export SECRET_KEY=" + canaryValue, canaryValue, ClassKeyValue, nil},
		{"log fields in one line", "ts=1 user=operator password=" + canaryValue + " action=login", canaryValue, ClassKeyValue, []string{"user=operator", "action=login"}},
		{"upper case name", "ADMIN_PWD=" + canaryValue, canaryValue, ClassKeyValue, nil},
		{"command line flag", "run --password " + canaryValue + " --verbose", canaryValue, ClassCLIFlag, []string{"--verbose"}},
		{"command line flag with quotes", `run --api-token "` + canaryValue + ` with space" --verbose`, "with space", ClassCLIFlag, []string{"--verbose"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Apply(tt.input)
			if strings.Contains(got.Text, tt.canary) {
				t.Errorf("the canary is still in the output:\n%s", got.Text)
			}
			if got.Counts[tt.class] < 1 {
				t.Errorf("Counts[%q] = %d, want 1 or more (counts: %v)\n%s", tt.class, got.Counts[tt.class], got.Counts, got.Text)
			}
			if !strings.Contains(got.Text, markerPrefix) {
				t.Errorf("the output has no marker:\n%s", got.Text)
			}
			for _, keep := range tt.keeps {
				if !strings.Contains(got.Text, keep) {
					t.Errorf("the output lost the text %q:\n%s", keep, got.Text)
				}
			}
		})
	}
}

func TestApplyKeepsOrdinaryText(t *testing.T) {
	hex64 := rep("0123456789abcdef", 4)
	tests := []struct {
		name  string
		input string
	}{
		{"image digest", "image: ghcr.io/example/app@sha256:" + hex64},
		{"model digest in a lock file", `{"tag":"small:1","digest":"` + hex64 + `","vram_mib":3158}`},
		{"image tag of a name with a secret word", "image: quay.io/example/keycloak:26.0.1"},
		{"host and port of a name with a secret word", "upstream pgadmin:8080 is healthy"},
		{"git commit", "commit 27a5e90f3c1d4b6a8e9f0a1b2c3d4e5f6a7b8c9d"},
		{"UUID", "request 123e4567-e89b-12d3-a456-426614174000 done"},
		{"log fields", "status=200 duration=5ms bytes=1024 method=GET"},
		{"URL with a port", "GET http://service.example:8080/health 200"},
		{"timestamp", "2026-11-15T10:00:00+01:00 INFO started"},
		{"prose with the secret words", "The keyboard layout is Italian. Rotate the passwords and the tokens each year."},
		{"heading", "## Tokens, keys and credentials"},
		{"the word bearer in prose", "the bearer of the message"},
		{"YAML key with a nested map", "secrets:\n  db_data:\n    external: true"},
		{"JSON key with a list", "\"api_keys\": [\n  \"see the vault\"\n]"},
		{"Windows path", `C:\Program Files\Tool\bin\tool.exe`},
		{"shell variable", "echo ${HOME} and $PATH"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Apply(tt.input)
			if got.Text != tt.input {
				t.Errorf("Apply changed ordinary text:\n in: %s\nout: %s", tt.input, got.Text)
			}
			if got.Total() != 0 {
				t.Errorf("Total = %d, want 0 (counts: %v)", got.Total(), got.Counts)
			}
		})
	}
}

func TestApplyCounts(t *testing.T) {
	input := strings.Join([]string{
		"API_KEY=" + canaryValue,
		"token " + canaryGhp,
		"other " + canaryGhp,
		"jwt " + canaryJWT,
	}, "\n")
	got := Apply(input)
	want := map[string]int{ClassKeyValue: 1, ClassGitHubToken: 2, ClassJWT: 1}
	for class, n := range want {
		if got.Counts[class] != n {
			t.Errorf("Counts[%q] = %d, want %d", class, got.Counts[class], n)
		}
	}
	if got.Total() != 4 {
		t.Errorf("Total = %d, want 4 (counts: %v)", got.Total(), got.Counts)
	}
}

// A name with a secret word and a specific token as the value: the marker
// of the specific rule stays, and the general rule does not count it again.
func TestApplySpecificClassWins(t *testing.T) {
	got := Apply("GITHUB_TOKEN=" + canaryGhp + "\nlog token=" + canaryJWT + " ok")
	if got.Counts[ClassKeyValue] != 0 {
		t.Errorf("the general rule counted a value that was already a marker: %v\n%s", got.Counts, got.Text)
	}
	for _, marker := range []string{markerPrefix + ClassGitHubToken + "]", markerPrefix + ClassJWT + "]"} {
		if !strings.Contains(got.Text, marker) {
			t.Errorf("the output has no marker %s:\n%s", marker, got.Text)
		}
	}
}

func TestApplyTwiceChangesNothing(t *testing.T) {
	input := strings.Join([]string{
		"POSTGRES_PASSWORD=" + canaryValue,
		`{"api_key":"` + canaryValue + `"}`,
		"Authorization: Bearer " + canaryValue,
		"run --password " + canaryValue,
		"postgres://app:" + canaryValue + "@db.example/app",
		pemBlock("", "\n"),
		"bot" + canaryTelegram + "/getMe",
		"user=operator password=" + canaryValue + " action=login",
	}, "\n")
	first := Apply(input)
	second := Apply(first.Text)
	if second.Text != first.Text {
		t.Errorf("the second pass changed the text:\nfirst:  %s\nsecond: %s", first.Text, second.Text)
	}
	if second.Total() != 0 {
		t.Errorf("the second pass counted %d replacements: %v", second.Total(), second.Counts)
	}
}

func TestMergeCounts(t *testing.T) {
	got := MergeCounts(nil, map[string]int{ClassJWT: 1})
	got = MergeCounts(got, map[string]int{ClassJWT: 2, ClassPEM: 1})
	if got[ClassJWT] != 3 || got[ClassPEM] != 1 {
		t.Errorf("MergeCounts = %v", got)
	}
}
