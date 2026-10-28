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

// Copy of tools/komodo-gate/notify.go: the same token handling in errors.

type notifier interface {
	Send(ctx context.Context, text string) error
}

type telegramNotifier struct {
	botToken string
	chatID   string
	http     *http.Client
	baseURL  string // https://api.telegram.org, the tests replace it
}

func (t *telegramNotifier) Send(ctx context.Context, text string) error {
	form := url.Values{"chat_id": {t.chatID}, "text": {text}}
	endpoint := t.baseURL + "/bot" + t.botToken + "/sendMessage"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return errors.New("telegram: richiesta non valida") // the error would contain the URL, that is the token
	}
	req.Header.Set("content-type", "application/x-www-form-urlencoded")

	resp, err := t.http.Do(req)
	if err != nil {
		// *url.Error prints the full URL with the token: keep only the cause.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return fmt.Errorf("telegram: invio fallito: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
		return fmt.Errorf("telegram: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(snippet)))
	}
	return nil
}

// printNotifier for -dry-run: it prints instead of a send.
type printNotifier struct{ out io.Writer }

func (p printNotifier) Send(_ context.Context, text string) error {
	_, err := fmt.Fprintf(p.out, "[DRY_RUN] messaggio che verrebbe inviato:\n%s\n", text)
	return err
}
