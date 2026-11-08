package yam

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

var APIBase = "https://api.music.yandex.net"

const (
	userAgent    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) YAMP/2.0"
	clientHeader = "YandexMusicAndroid/24023621"
)

var ErrUnauthorized = errors.New("токен недействителен или устарел, получите новый")

var transport = &http.Transport{
	Proxy: http.ProxyFromEnvironment,
	DialContext: (&net.Dialer{
		Timeout:   15 * time.Second,
		KeepAlive: 30 * time.Second,
	}).DialContext,
	ForceAttemptHTTP2:     true,
	MaxIdleConns:          64,
	MaxIdleConnsPerHost:   16,
	IdleConnTimeout:       90 * time.Second,
	TLSHandshakeTimeout:   15 * time.Second,
	ResponseHeaderTimeout: 30 * time.Second,
	ReadBufferSize:        256 << 10,
}

var defaultHTTP = &http.Client{Transport: transport}

type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string {
	switch e.Status {
	case http.StatusUnavailableForLegalReasons:
		return "недоступно в вашем регионе"
	case http.StatusNotFound:
		return "не найдено"
	}
	if e.Message != "" {
		return fmt.Sprintf("HTTP %d: %s", e.Status, e.Message)
	}
	return fmt.Sprintf("HTTP %d", e.Status)
}

type Client struct {
	token string
	http  *http.Client
	base  string
}

func New(token string) *Client {
	return &Client{token: strings.TrimSpace(token), http: defaultHTTP, base: APIBase}
}

func formBody(form url.Values) (io.Reader, string) {
	if form == nil {
		return nil, ""
	}
	return strings.NewReader(form.Encode()), "application/x-www-form-urlencoded"
}

func (c *Client) newRequest(ctx context.Context, method, rawURL string, body io.Reader, contentType string, auth bool) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, method, rawURL, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("X-Yandex-Music-Client", clientHeader)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}

	if auth {
		req.Header.Set("Accept", "application/json")
		if c.token != "" {
			req.Header.Set("Authorization", "OAuth "+c.token)
		}
	}
	return req, nil
}

func (c *Client) fetch(ctx context.Context, method, rawURL string, form url.Values, auth bool) ([]byte, error) {
	body, contentType := formBody(form)
	return c.send(ctx, method, rawURL, body, contentType, auth)
}

func (c *Client) send(ctx context.Context, method, rawURL string, body io.Reader, contentType string, auth bool) ([]byte, error) {
	req, err := c.newRequest(ctx, method, rawURL, body, contentType, auth)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		if auth && resp.StatusCode == http.StatusUnauthorized {
			return nil, ErrUnauthorized
		}
		return nil, &APIError{Status: resp.StatusCode, Message: apiErrorMessage(b)}
	}
	return b, nil
}

func (c *Client) api(ctx context.Context, method, path string, form url.Values, out any) error {
	b, err := c.fetch(ctx, method, c.base+path, form, true)
	if err != nil {
		return err
	}
	return decodeResult(b, out)
}

func (c *Client) postJSON(ctx context.Context, path string, in, out any) error {
	data, err := json.Marshal(in)
	if err != nil {
		return err
	}
	b, err := c.send(ctx, http.MethodPost, c.base+path, bytes.NewReader(data), "application/json", true)
	if err != nil {
		return err
	}
	return decodeResult(b, out)
}

func decodeResult(b []byte, out any) error {
	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(b, &envelope); err != nil {
		return fmt.Errorf("сервер вернул не JSON (%s)", snippet(b))
	}
	if len(envelope.Result) == 0 || string(envelope.Result) == "null" {
		if msg := apiErrorMessage(b); msg != "" {
			return &APIError{Status: http.StatusOK, Message: msg}
		}
		return &APIError{Status: http.StatusNotFound}
	}
	if err := json.Unmarshal(envelope.Result, out); err != nil {
		return fmt.Errorf("неожиданный ответ API: %w", err)
	}
	return nil
}

func apiErrorMessage(b []byte) string {
	var e struct {
		Error struct {
			Name    string `json:"name"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(b, &e) != nil {
		return ""
	}
	if e.Error.Message != "" {
		return e.Error.Message
	}
	return e.Error.Name
}

func snippet(b []byte) string {
	s := strings.Join(strings.Fields(string(b)), " ")
	if r := []rune(s); len(r) > 80 {
		s = string(r[:80]) + "…"
	}
	return s
}

type flexID string

func (f *flexID) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	if s == "null" {
		s = ""
	}
	*f = flexID(s)
	return nil
}

type flexInt int

func (f *flexInt) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	var n int
	if _, err := fmt.Sscan(s, &n); err != nil {
		n = 0
	}
	*f = flexInt(n)
	return nil
}
