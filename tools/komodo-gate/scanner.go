package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
)

type scanResult struct {
	// OS that Trivy identifies ("alpine 3.23.6"), "" if none. Some images have only
	// the binary. Trivy does not identify some OS. Then Trivy does not scan
	// the OS packages and shows 0, not an error.
	OS         string
	Total      int
	BySeverity map[string]int
	// IDs of the CRITICAL/HIGH vulnerabilities, to find the new ones in the candidate.
	Serious map[string]bool
}

type scanner interface {
	// UpdateDB updates the databases one time for each run. Then all the scans use
	// the same database. If not, the current image and the candidate use different data.
	UpdateDB(ctx context.Context) error
	Scan(ctx context.Context, ref string) (scanResult, error)
}

// trivyScanner starts Trivy as a temporary container (`docker run --rm`).
// There is no Docker socket in the container: it scans from the registry
// (--image-src remote), also the current image, by digest. The cache (database +
// layer analysis) is in its own volume.
type trivyScanner struct {
	image       string // tag + digest, for example aquasec/trivy:0.74.0@sha256:...
	cacheVolume string
	platform    string
}

func (t *trivyScanner) dockerArgs(trivyArgs ...string) []string {
	args := []string{"run", "--rm", "-v", t.cacheVolume + ":/root/.cache/trivy", t.image}
	return append(args, trivyArgs...)
}

func (t *trivyScanner) run(ctx context.Context, trivyArgs ...string) ([]byte, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "docker", t.dockerArgs(trivyArgs...)...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%w: %s", err, lastChars(strings.TrimSpace(stderr.String()), 300))
	}
	return stdout.Bytes(), nil
}

func (t *trivyScanner) UpdateDB(ctx context.Context) error {
	if _, err := t.run(ctx, "image", "--download-db-only", "--quiet"); err != nil {
		return fmt.Errorf("aggiornamento DB vulnerabilita': %w", err)
	}
	// Necessary for .jar files (for example tika): without it, --skip-java-db-update fails at the first run.
	if _, err := t.run(ctx, "image", "--download-java-db-only", "--quiet"); err != nil {
		return fmt.Errorf("aggiornamento DB Java: %w", err)
	}
	return nil
}

func (t *trivyScanner) Scan(ctx context.Context, ref string) (scanResult, error) {
	out, err := t.run(ctx, "image",
		"--image-src", "remote",
		"--platform", t.platform,
		"--scanners", "vuln",
		"--skip-db-update", "--skip-java-db-update",
		"--format", "json", "--quiet",
		"--timeout", "15m",
		ref)
	if err != nil {
		return scanResult{}, err
	}
	return parseTrivyJSON(out)
}

func parseTrivyJSON(data []byte) (scanResult, error) {
	var report struct {
		Metadata struct {
			OS *struct {
				Family string `json:"Family"`
				Name   string `json:"Name"`
			} `json:"OS"`
		} `json:"Metadata"`
		Results []struct {
			Vulnerabilities []struct {
				VulnerabilityID string `json:"VulnerabilityID"`
				Severity        string `json:"Severity"`
			} `json:"Vulnerabilities"`
		} `json:"Results"`
	}
	if err := json.Unmarshal(data, &report); err != nil {
		return scanResult{}, fmt.Errorf("report di Trivy non leggibile: %w", err)
	}
	res := scanResult{BySeverity: map[string]int{}, Serious: map[string]bool{}}
	if detected := report.Metadata.OS; detected != nil && detected.Family != "" {
		res.OS = strings.TrimSpace(detected.Family + " " + detected.Name)
	}
	// Count as the Trivy "Total": one item for each package, so the same CVE
	// on two packages counts two times. This is the same for the current image and the candidate.
	for _, r := range report.Results {
		for _, v := range r.Vulnerabilities {
			res.Total++
			res.BySeverity[v.Severity]++
			if v.Severity == "CRITICAL" || v.Severity == "HIGH" {
				res.Serious[v.VulnerabilityID] = true
			}
		}
	}
	return res, nil
}

func lastChars(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "..." + s[len(s)-n:]
}
