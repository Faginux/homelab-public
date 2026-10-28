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

// Minimal client for the Komodo v2.3.3 API: only POST /read ListServers.
//
// RULE (as in komodo-gate): ListServers also returns addresses, the public IP
// and the public keys of the Periphery agents. The structs below list only the fields in use:
// encoding/json discards the other fields, so they never go into logs, state or messages.

type komodoAPI interface {
	ListServers(ctx context.Context) ([]serverListItem, error)
}

type serverListItem struct {
	Name string `json:"name"`
	Info struct {
		// Enum ServerState: "Ok", "NotOk", "Disabled". The strum kebab-case in the
		// source applies only to Display, not to the JSON.
		State string `json:"state"`
		Err   *struct {
			Error string `json:"error"`
		} `json:"err"`
	} `json:"info"`
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
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		return fmt.Errorf("%s: HTTP %d: %s", requestType, resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return fmt.Errorf("%s: risposta non leggibile: %w", requestType, err)
	}
	return nil
}

func (c *komodoClient) ListServers(ctx context.Context) ([]serverListItem, error) {
	var servers []serverListItem
	err := c.read(ctx, "ListServers", map[string]any{}, &servers)
	return servers, err
}
