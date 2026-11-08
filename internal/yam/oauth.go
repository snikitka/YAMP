package yam

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

const (
	oauthBase    = "https://oauth.yandex.ru"
	clientID     = "23cabbbdc6cd418abb4b39c32c41195d"
	clientSecret = "53bc75238f0c4d08a118e51fe9203300"
)

var (
	ErrPending  = errors.New("вход ещё не подтверждён")
	ErrSlowDown = errors.New("Яндекс просит опрашивать реже")
	ErrExpired  = errors.New("код истёк, получите новый")
	ErrDenied   = errors.New("вход отклонён")
)

type DeviceCode struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURL string `json:"verification_url"`
	Interval        int    `json:"interval"`
	ExpiresIn       int    `json:"expires_in"`
}

type Grant struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
}

func (g Grant) Expires(now time.Time) time.Time {
	return now.Add(time.Duration(g.ExpiresIn) * time.Second)
}

type OAuth struct {
	base string
	http *http.Client
}

func NewOAuth() *OAuth {
	return &OAuth{base: oauthBase, http: defaultHTTP}
}

type oauthError struct {
	Status      int
	Code        string `json:"error"`
	Description string `json:"error_description"`
}

func (e *oauthError) Error() string {
	if e.Description != "" {
		return fmt.Sprintf("Яндекс OAuth: %s (%s)", e.Description, e.Code)
	}
	if e.Code != "" {
		return "Яндекс OAuth: " + e.Code
	}
	return "Яндекс OAuth: HTTP " + strconv.Itoa(e.Status)
}

func (o *OAuth) post(ctx context.Context, path string, form url.Values, out any) error {
	form.Set("client_id", clientID)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.base+path, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := o.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		e := &oauthError{Status: resp.StatusCode}
		_ = json.Unmarshal(b, e)
		return e
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(b, out); err != nil {
		return fmt.Errorf("Яндекс OAuth вернул не JSON (%s)", snippet(b))
	}
	return nil
}

func (o *OAuth) DeviceCode(ctx context.Context, deviceID, deviceName string) (DeviceCode, error) {
	var d DeviceCode
	err := o.post(ctx, "/device/code", url.Values{"device_id": {deviceID}, "device_name": {deviceName}}, &d)
	if err == nil && (d.DeviceCode == "" || d.UserCode == "") {
		err = errors.New("Яндекс OAuth не выдал код")
	}
	if d.Interval <= 0 {
		d.Interval = 5
	}
	if d.VerificationURL == "" {
		d.VerificationURL = "https://ya.ru/device"
	}
	return d, err
}

func (o *OAuth) token(ctx context.Context, form url.Values) (Grant, error) {
	form.Set("client_secret", clientSecret)
	var g Grant
	err := o.post(ctx, "/token", form, &g)
	var oe *oauthError
	if errors.As(err, &oe) {
		switch oe.Code {
		case "authorization_pending":
			return g, ErrPending
		case "slow_down":
			return g, ErrSlowDown
		case "expired_token":
			return g, ErrExpired
		case "access_denied":
			return g, ErrDenied
		}
	}
	if err == nil && g.AccessToken == "" {
		err = errors.New("Яндекс OAuth не выдал токен")
	}
	return g, err
}

func (o *OAuth) PollDevice(ctx context.Context, deviceCode string) (Grant, error) {
	return o.token(ctx, url.Values{"grant_type": {"device_code"}, "code": {deviceCode}})
}

func (o *OAuth) Refresh(ctx context.Context, refreshToken string) (Grant, error) {
	return o.token(ctx, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refreshToken}})
}

func (o *OAuth) Revoke(ctx context.Context, accessToken string) error {
	return o.post(ctx, "/revoke_token", url.Values{"access_token": {accessToken}, "client_secret": {clientSecret}}, nil)
}
