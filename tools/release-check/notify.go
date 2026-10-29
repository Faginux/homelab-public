package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

type notifier interface {
	Send(ctx context.Context, text string) error
}

type telegramNotifier struct {
	botToken string
	chatID   string
	http     *http.Client
	baseURL  string // https://api.telegram.org, replaced in tests
}

func (t *telegramNotifier) Send(ctx context.Context, text string) error {
	// The text is HTML: buildMessage escapes it and uses <pre> for the block to paste.
	form := url.Values{"chat_id": {t.chatID}, "text": {text}, "parse_mode": {"HTML"}}
	endpoint := t.baseURL + "/bot" + t.botToken + "/sendMessage"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return errors.New("telegram: invalid request") // the error would hold the URL, so the token
	}
	req.Header.Set("content-type", "application/x-www-form-urlencoded")

	resp, err := t.http.Do(req)
	if err != nil {
		// *url.Error prints the full URL, token included: keep only the cause.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return fmt.Errorf("telegram: send failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
		return fmt.Errorf("telegram: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	return nil
}

// printNotifier is for the dry run: it prints instead of sending.
type printNotifier struct{ out io.Writer }

func (p printNotifier) Send(_ context.Context, text string) error {
	_, err := fmt.Fprintf(p.out, "[DRY_RUN] message that would be sent:\n%s\n", text)
	return err
}
