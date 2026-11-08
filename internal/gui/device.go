package gui

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"runtime"
	"time"

	"yamp/internal/yam"
)

const (
	refreshBefore = 30 * 24 * time.Hour
	oauthTimeout  = 20 * time.Second
)

type deviceEvent struct {
	Type      string `json:"type"`
	Status    string `json:"status"`
	Code      string `json:"code,omitempty"`
	URL       string `json:"url,omitempty"`
	ExpiresIn int    `json:"expiresIn,omitempty"`
	Message   string `json:"message,omitempty"`
}

func deviceName() string {
	switch runtime.GOOS {
	case "windows":
		return "YAMP (Windows)"
	case "darwin":
		return "YAMP (macOS)"
	case "linux":
		return "YAMP (Linux)"
	case "android":
		return "YAMP (Android)"
	}
	return "YAMP"
}

func newDeviceID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func (g *App) deviceLogin() {
	ctx, cancel := context.WithCancel(context.Background())
	g.mu.Lock()
	if g.deviceCancel != nil {
		g.deviceCancel()
	}
	g.deviceCancel = cancel
	var saveErr error
	if g.cfg.DeviceID == "" {
		g.cfg.DeviceID = newDeviceID()
		saveErr = g.cfg.save()
	}
	id := g.cfg.DeviceID
	g.mu.Unlock()
	if saveErr != nil {
		g.notice("Не удалось сохранить настройки: "+saveErr.Error(), "error")
	}
	go g.runDeviceLogin(ctx, id)
}

func (g *App) deviceCancelLogin() {
	g.mu.Lock()
	if g.deviceCancel != nil {
		g.deviceCancel()
		g.deviceCancel = nil
	}
	g.mu.Unlock()
}

func (g *App) emitDevice(ctx context.Context, e deviceEvent) {
	if ctx.Err() != nil {
		return
	}
	e.Type = "deviceLogin"
	g.emit(e)
}

func (g *App) runDeviceLogin(ctx context.Context, id string) {
	o := yam.NewOAuth()
	rctx, rcancel := context.WithTimeout(ctx, oauthTimeout)
	code, err := o.DeviceCode(rctx, id, deviceName())
	rcancel()
	if err != nil {
		g.emitDevice(ctx, deviceEvent{Status: "error", Message: "Не удалось получить код входа: " + err.Error()})
		return
	}
	g.emitDevice(ctx, deviceEvent{Status: "code", Code: code.UserCode, URL: code.VerificationURL, ExpiresIn: code.ExpiresIn})

	deadline := time.Now().Add(time.Duration(code.ExpiresIn) * time.Second)
	interval := time.Duration(code.Interval) * time.Second
	for {
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
		if time.Now().After(deadline) {
			g.emitDevice(ctx, deviceEvent{Status: "expired"})
			return
		}
		pctx, pcancel := context.WithTimeout(ctx, oauthTimeout)
		grant, err := o.PollDevice(pctx, code.DeviceCode)
		pcancel()
		switch {
		case ctx.Err() != nil:
			return
		case errors.Is(err, yam.ErrPending):
			continue
		case errors.Is(err, yam.ErrSlowDown):
			interval += 5 * time.Second
			continue
		case errors.Is(err, yam.ErrExpired):
			g.emitDevice(ctx, deviceEvent{Status: "expired"})
			return
		case errors.Is(err, yam.ErrDenied):
			g.emitDevice(ctx, deviceEvent{Status: "error", Message: "Вход отклонён на странице Яндекса"})
			return
		case err != nil:
			g.logf("Вход по коду: %v", err)
			continue
		}

		g.mu.Lock()
		if ctx.Err() != nil {
			g.mu.Unlock()
			return
		}
		g.deviceCancel = nil
		g.grant = &grant
		g.mu.Unlock()
		g.emit(deviceEvent{Type: "deviceLogin", Status: "done"})
		g.checkAccount(grant.AccessToken, true)
		return
	}
}

func (g *App) refreshGrant() {
	g.mu.Lock()
	refresh, expires, token := g.cfg.refresh(), time.Unix(g.cfg.Expires, 0), g.token
	g.mu.Unlock()
	if refresh == "" || time.Until(expires) > refreshBefore {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), oauthTimeout)
	defer cancel()
	grant, err := yam.NewOAuth().Refresh(ctx, refresh)
	if err != nil {
		g.logf("Не удалось продлить вход: %v", err)
		return
	}

	g.mu.Lock()
	if g.token != token {
		g.mu.Unlock()
		return
	}
	same := grant.AccessToken == token
	var saveErr error
	if same {
		if saveErr = g.cfg.setGrant(&grant); saveErr == nil {
			saveErr = g.cfg.save()
		}
	} else {
		g.grant = &grant
	}
	g.mu.Unlock()

	if !same {
		g.checkAccount(grant.AccessToken, true)
		return
	}
	if saveErr != nil {
		g.logf("Не удалось сохранить продлённый вход: %v", saveErr)
		return
	}
	g.logf("Вход продлён до %s", grant.Expires(time.Now()).Format("02.01.2006"))
}

func (g *App) revoke(token string) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), oauthTimeout)
		defer cancel()
		if err := yam.NewOAuth().Revoke(ctx, token); err != nil {
			g.logf("Не удалось отозвать токен: %v", err)
			return
		}
		g.logf("Токен этого устройства отозван")
	}()
}
