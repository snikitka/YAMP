package gui

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"yamp/internal/yam"
)

func TestGateLimit(t *testing.T) {
	g := newGate(3)
	var active, peak atomic.Int32
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := g.acquire(context.Background()); err != nil {
				t.Error(err)
				return
			}
			n := active.Add(1)
			for {
				p := peak.Load()
				if n <= p || peak.CompareAndSwap(p, n) {
					break
				}
			}
			time.Sleep(5 * time.Millisecond)
			active.Add(-1)
			g.release()
		}()
	}
	wg.Wait()
	if p := peak.Load(); p != 3 {
		t.Errorf("пик одновременных = %d, want 3", p)
	}
}

func TestGateCancelAndResize(t *testing.T) {
	g := newGate(1)
	if err := g.acquire(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	errc := make(chan error)
	go func() { errc <- g.acquire(ctx) }()
	cancel()
	if err := <-errc; err == nil {
		t.Fatal("отменённое ожидание получило слот")
	}

	got := make(chan struct{})
	go func() {
		_ = g.acquire(context.Background())
		close(got)
	}()
	time.Sleep(10 * time.Millisecond)
	g.setLimit(2)
	select {
	case <-got:
	case <-time.After(time.Second):
		t.Fatal("ждущий не получил слот после увеличения лимита")
	}
}

func TestExtractToken(t *testing.T) {
	cases := map[string]string{
		"  y0_AgAAAAB-abc  ": "y0_AgAAAAB-abc",
		"https://music.yandex.ru/#access_token=y0_AgAA-xyz&token_type=bearer&expires_in=31535645": "y0_AgAA-xyz",
		"https://oauth.yandex.ru/verification_code#access_token=AQAAAA123&state=":                 "AQAAAA123",
	}
	for in, want := range cases {
		if got := extractToken(in); got != want {
			t.Errorf("extractToken(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestProtectRoundTrip(t *testing.T) {
	secret := []byte("y0_AgAAAAB-test-token")
	sealed, err := protect(secret)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := unprotect(sealed)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(plain, secret) {
		t.Errorf("unprotect = %q", plain)
	}

	var c config
	if err := c.setToken(string(secret)); err != nil {
		t.Fatal(err)
	}
	if c.token() != string(secret) {
		t.Errorf("config.token() не восстановил токен")
	}
	if bytes.Contains([]byte(c.Token), secret) {
		t.Errorf("токен лежит в конфиге открытым текстом")
	}
}

func TestSearchError(t *testing.T) {
	cases := map[error]string{
		errors.New(`Get "https://api.music.yandex.net/search": dial tcp: no such host`): "Нет связи с Яндекс Музыкой. Проверьте подключение и повторите.",
		fmt.Errorf("x: %w", context.DeadlineExceeded):                                   "Яндекс Музыка не ответила вовремя. Проверьте подключение и повторите.",
		&yam.APIError{Status: 500}:                                                      "Яндекс Музыка ответила ошибкой (HTTP 500). Повторите чуть позже.",
		yam.ErrUnauthorized:                                                             yam.ErrUnauthorized.Error(),
	}
	for err, want := range cases {
		if got := searchError(err); got != want {
			t.Errorf("searchError(%v) = %q, want %q", err, got, want)
		}
	}
}

func TestCoreLifecycle(t *testing.T) {
	dir := t.TempDir()
	for _, v := range []string{"AppData", "HOME", "XDG_CONFIG_HOME"} {
		t.Setenv(v, dir)
	}
	events := make(chan map[string]any, 64)
	core := Start(func(event []byte) {
		var e map[string]any
		if err := json.Unmarshal(event, &e); err != nil {
			t.Errorf("событие не JSON: %q", event)
			return
		}
		events <- e
	})
	next := func() map[string]any {
		select {
		case e := <-events:
			return e
		case <-time.After(5 * time.Second):
			t.Fatal("ядро не прислало событие")
			return nil
		}
	}

	core.Send([]byte("not json"))
	core.Send([]byte(`{"theme":"light"}`))
	core.Send([]byte(`{"cmd":"prefs","theme":"light"}`))
	if e := next(); e["type"] != "state" || e["theme"] != "light" || e["version"] != Version {
		t.Fatalf("ждали state с темой light, пришло %v", e)
	}
	core.Send([]byte(`{"cmd":"prefs","crossfade":false,"fade":40}`))
	if e := next(); e["crossfade"] != false || e["fade"] != float64(maxFade) {
		t.Fatalf("ждали выключенные переходы и %d с, пришло %v", maxFade, e)
	}
	core.Send([]byte(`{"cmd":"prefs","crossfade":true}`))
	if e := next(); e["crossfade"] != true || e["fade"] != float64(maxFade) {
		t.Fatalf("переходы не включились обратно с прежней длиной: %v", e)
	}

	core.Close()
	if e := next(); e["type"] != "exit" {
		t.Fatalf("ждали exit, пришло %v", e)
	}
	done := make(chan struct{})
	go func() {
		core.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Wait не вернулся после Close")
	}

	core.Send([]byte(`{"cmd":"prefs","theme":"dark"}`))
	core.app.emitState(false)
	select {
	case e := <-events:
		t.Fatalf("событие после exit: %v", e)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestCrossfadeDefaults(t *testing.T) {
	c := defaultConfig()
	if !c.crossfade() || c.fade() != defaultFade {
		t.Fatalf("по умолчанию ждали переходы на %d с, а не %v %d", defaultFade, c.crossfade(), c.fade())
	}
	off := false
	c.Crossfade, c.Fade = &off, -3
	if c.crossfade() || c.fade() != minFade {
		t.Fatalf("ждали выключенные переходы и %d с, а не %v %d", minFade, c.crossfade(), c.fade())
	}
}

func TestGrantStorage(t *testing.T) {
	var c config
	g := &yam.Grant{AccessToken: "acc", RefreshToken: "y0_refresh-secret", ExpiresIn: 365 * 24 * 3600}
	if err := c.setGrant(g); err != nil {
		t.Fatal(err)
	}
	if c.refresh() != g.RefreshToken {
		t.Errorf("refresh() не восстановил refresh_token")
	}
	if bytes.Contains([]byte(c.Refresh), []byte(g.RefreshToken)) {
		t.Errorf("refresh_token лежит в конфиге открытым текстом")
	}
	if d := time.Until(time.Unix(c.Expires, 0)); d < 364*24*time.Hour || d > 366*24*time.Hour {
		t.Errorf("срок = %v", d)
	}
	if err := c.setGrant(nil); err != nil || c.Refresh != "" || c.Expires != 0 {
		t.Errorf("setGrant(nil) не очистил: %+v", c)
	}
}
