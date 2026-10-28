package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// registry is the part of the OCI distribution API that the tool uses.
type registry interface {
	Tags(ctx context.Context, ref imageRef) ([]string, error)
	Digest(ctx context.Context, ref imageRef, tag string) (string, error)
}

const (
	maxTagPages = 300 // ghcr.io/immich-app has thousands of tags
	maxRetries  = 3   // for 429 and 5xx
	manifestAcc = "application/vnd.oci.image.index.v1+json, " +
		"application/vnd.docker.distribution.manifest.list.v2+json, " +
		"application/vnd.oci.image.manifest.v1+json, " +
		"application/vnd.docker.distribution.manifest.v2+json"
)

// httpRegistry reads public images with an anonymous Bearer token. It never sends a
// credential: the tool has none.
type httpRegistry struct {
	http    *http.Client
	baseURL string            // test override; empty = https://<registry>
	tokens  map[string]string // cache: realm|service|scope -> token

	hostToken map[string]string                          // last token used for each registry host
	sleep     func(context.Context, time.Duration) error // replaced in tests
}

func newHTTPRegistry(c *http.Client) *httpRegistry {
	return &httpRegistry{http: c, tokens: map[string]string{}, hostToken: map[string]string{}, sleep: sleepContext}
}

func (h *httpRegistry) base(ref imageRef) string {
	if h.baseURL != "" {
		return h.baseURL
	}
	return "https://" + ref.Registry
}

func (h *httpRegistry) Tags(ctx context.Context, ref imageRef) ([]string, error) {
	next := h.base(ref) + "/v2/" + ref.Repo + "/tags/list?n=1000"
	var tags []string
	for page := 0; next != ""; page++ {
		if page >= maxTagPages {
			return nil, fmt.Errorf("more than %d tag pages", maxTagPages)
		}
		resp, err := h.do(ctx, http.MethodGet, next, "")
		if err != nil {
			return nil, err
		}
		var body struct {
			Tags []string `json:"tags"`
		}
		err = json.NewDecoder(io.LimitReader(resp.Body, 16<<20)).Decode(&body)
		resp.Body.Close()
		if err != nil {
			return nil, fmt.Errorf("tag list unreadable: %w", err)
		}
		tags = append(tags, body.Tags...)
		next = nextLink(resp, next)
	}
	return tags, nil
}

func (h *httpRegistry) Digest(ctx context.Context, ref imageRef, tag string) (string, error) {
	resp, err := h.do(ctx, http.MethodHead, h.base(ref)+"/v2/"+ref.Repo+"/manifests/"+tag, manifestAcc)
	if err != nil {
		return "", err
	}
	resp.Body.Close()
	d := resp.Header.Get("Docker-Content-Digest")
	if d == "" {
		return "", errors.New("registry sent no digest")
	}
	return d, nil
}

// nextLink reads `Link: <...>; rel="next"` and resolves it against the current URL.
func nextLink(resp *http.Response, current string) string {
	link := resp.Header.Get("Link")
	if link == "" || !strings.Contains(link, `rel="next"`) {
		return ""
	}
	start, end := strings.Index(link, "<"), strings.Index(link, ">")
	if start < 0 || end < start {
		return ""
	}
	base, err := url.Parse(current)
	if err != nil {
		return ""
	}
	ref, err := url.Parse(link[start+1 : end])
	if err != nil {
		return ""
	}
	return base.ResolveReference(ref).String()
}

// do sends a request. On 401 with a Bearer challenge it gets an anonymous token and
// retries once. On 429 and 5xx it waits and retries up to maxRetries times. The body
// of a successful response is the caller's to close.
func (h *httpRegistry) do(ctx context.Context, method, target, accept string) (*http.Response, error) {
	u, err := url.Parse(target)
	if err != nil {
		return nil, err
	}
	bearer := h.hostToken[u.Host] // last token of this host: saves a 401 on every page
	authTried, retries := false, 0
	for {
		req, err := http.NewRequestWithContext(ctx, method, target, nil)
		if err != nil {
			return nil, err
		}
		if accept != "" {
			req.Header.Set("Accept", accept)
		}
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp, err := h.http.Do(req)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode == http.StatusOK {
			return resp, nil
		}
		challenge := resp.Header.Get("Www-Authenticate")
		retryAfter := resp.Header.Get("Retry-After")
		code := resp.StatusCode
		resp.Body.Close()

		switch {
		case code == http.StatusUnauthorized && !authTried && strings.HasPrefix(challenge, "Bearer "):
			authTried = true
			if bearer, err = h.fetchToken(ctx, challenge); err != nil {
				return nil, err
			}
			h.hostToken[u.Host] = bearer
		case (code == http.StatusTooManyRequests || code >= 500) && retries < maxRetries:
			retries++
			if err := h.sleep(ctx, backoff(retries, retryAfter)); err != nil {
				return nil, err
			}
		default:
			return nil, fmt.Errorf("HTTP %d", code)
		}
	}
}

// backoff waits Retry-After seconds when the registry sends it (at most 30), otherwise 2, 4, 8 s.
func backoff(retry int, retryAfter string) time.Duration {
	if secs, err := strconv.Atoi(retryAfter); err == nil && secs > 0 {
		return min(time.Duration(secs)*time.Second, 30*time.Second)
	}
	return time.Duration(1<<retry) * time.Second
}

func sleepContext(ctx context.Context, d time.Duration) error {
	select {
	case <-time.After(d):
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (h *httpRegistry) fetchToken(ctx context.Context, challenge string) (string, error) {
	params := map[string]string{}
	for _, part := range strings.Split(strings.TrimPrefix(challenge, "Bearer "), ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if ok {
			params[k] = strings.Trim(v, `"`)
		}
	}
	realm := params["realm"]
	if realm == "" {
		return "", errors.New("auth challenge without realm")
	}
	cacheKey := realm + "|" + params["service"] + "|" + params["scope"]
	if t, ok := h.tokens[cacheKey]; ok {
		return t, nil
	}
	q := url.Values{}
	if params["service"] != "" {
		q.Set("service", params["service"])
	}
	if params["scope"] != "" {
		q.Set("scope", params["scope"])
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, realm+"?"+q.Encode(), nil)
	if err != nil {
		return "", err
	}
	resp, err := h.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("anonymous token: HTTP %d", resp.StatusCode)
	}
	var body struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&body); err != nil {
		return "", fmt.Errorf("anonymous token unreadable: %w", err)
	}
	token := body.Token
	if token == "" {
		token = body.AccessToken
	}
	if token == "" {
		return "", errors.New("anonymous token empty")
	}
	h.tokens[cacheKey] = token
	return token, nil
}
