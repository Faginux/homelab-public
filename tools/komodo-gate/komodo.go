package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Minimal client for the Komodo v2.3.3 API: only POST /read, only the fields in use.
//
// RULE: with only the Read permission, GetStack also returns `config`,
// `deployed_config` and `deployed_contents` (the resolved compose config).
// The structs below list only the necessary fields. encoding/json discards
// all the other fields, so they never go into logs, state or messages.
// Do not add fields "because it is easy" before you read this note again.

type komodoAPI interface {
	ListStacks(ctx context.Context) ([]stackListItem, error)
	GetStack(ctx context.Context, stack string) (stackDetail, error)
	ListStackServices(ctx context.Context, stack string) ([]stackService, error)
}

type stackListItem struct {
	Name string `json:"name"`
	Info struct {
		Services []struct {
			Service         string `json:"service"`
			Image           string `json:"image"`
			UpdateAvailable bool   `json:"update_available"`
		} `json:"services"`
	} `json:"info"`
}

type stackDetail struct {
	Info struct {
		// The Komodo poll writes these. image_digest is "image:tag@sha256:...",
		// the digest from the registry (candidate).
		LatestServices []struct {
			ServiceName string  `json:"service_name"`
			ImageDigest *string `json:"image_digest"`
		} `json:"latest_services"`
	} `json:"info"`
}

type stackService struct {
	Service string `json:"service"`
	// Digest of the image of the container that runs now ("repo@sha256:...").
	ImageDigests []string `json:"image_digests"`
}

type komodoClient struct {
	baseURL   string
	apiKey    string
	apiSecret string
	http      *http.Client
}

func (c *komodoClient) read(ctx context.Context, requestType string, params, out any) error {
	body, err := json.Marshal(map[string]any{"type": requestType, "params": params})
	if err != nil {
		return fmt.Errorf("%s: %w", requestType, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/read", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("%s: %w", requestType, err)
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-api-key", c.apiKey)
	req.Header.Set("x-api-secret", c.apiSecret)

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("%s: %w", requestType, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// The Komodo errors are {"error": ..., "trace": [...]}: short, without config.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return fmt.Errorf("%s: HTTP %d: %s", requestType, resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("%s: risposta non leggibile: %w", requestType, err)
	}
	return nil
}

func (c *komodoClient) ListStacks(ctx context.Context) ([]stackListItem, error) {
	var stacks []stackListItem
	err := c.read(ctx, "ListStacks", map[string]any{}, &stacks)
	return stacks, err
}

func (c *komodoClient) GetStack(ctx context.Context, stack string) (stackDetail, error) {
	var detail stackDetail
	err := c.read(ctx, "GetStack", map[string]any{"stack": stack}, &detail)
	return detail, err
}

func (c *komodoClient) ListStackServices(ctx context.Context, stack string) ([]stackService, error) {
	var services []stackService
	err := c.read(ctx, "ListStackServices", map[string]any{"stack": stack}, &services)
	return services, err
}
