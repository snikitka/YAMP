package discord

import (
	"encoding/json"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

type fakeDiscord struct {
	t        *testing.T
	conn     net.Conn
	activity chan map[string]any
}

func (f *fakeDiscord) serve(reject string) {
	op, body, err := readFrame(f.conn)
	if err != nil || op != opHandshake {
		f.t.Errorf("handshake: op=%d err=%v", op, err)
		return
	}
	var hs struct {
		ClientID string `json:"client_id"`
	}
	json.Unmarshal(body, &hs)
	if hs.ClientID != "42" {
		f.t.Errorf("client_id = %q", hs.ClientID)
	}
	writeFrame(f.conn, opPing, map[string]any{"x": 1})
	if op, _, _ := readFrame(f.conn); op != opPong {
		f.t.Errorf("ожидался PONG, пришёл %d", op)
	}
	writeFrame(f.conn, opFrame, map[string]any{"cmd": "DISPATCH", "evt": "READY"})
	for {
		op, body, err := readFrame(f.conn)
		if err != nil {
			return
		}
		if op != opFrame {
			continue
		}
		var m struct {
			Cmd   string         `json:"cmd"`
			Nonce string         `json:"nonce"`
			Args  map[string]any `json:"args"`
		}
		json.Unmarshal(body, &m)
		act, _ := m.Args["activity"].(map[string]any)
		reply := map[string]any{"cmd": m.Cmd, "nonce": m.Nonce, "data": map[string]any{}}
		if reject != "" {
			reply["evt"] = "ERROR"
			reply["data"] = map[string]any{"message": reject}
		}
		writeFrame(f.conn, opFrame, reply)
		f.activity <- act
	}
}

func client(t *testing.T, reject string) (*Client, *fakeDiscord, chan string) {
	t.Helper()
	ours, theirs := net.Pipe()
	f := &fakeDiscord{t: t, conn: theirs, activity: make(chan map[string]any, 4)}
	go f.serve(reject)
	logs := make(chan string, 4)
	c := &Client{id: "42", updates: make(chan *Activity, 1), log: func(s string) { logs <- s }}
	c.dial = func() (io.ReadWriteCloser, error) { return ours, nil }
	go c.run()
	t.Cleanup(func() { ours.Close(); theirs.Close() })
	return c, f, logs
}

func next(t *testing.T, f *fakeDiscord) map[string]any {
	t.Helper()
	select {
	case a := <-f.activity:
		return a
	case <-time.After(2 * time.Second):
		t.Fatal("Discord не получил статус")
		return nil
	}
}

func TestSetActivity(t *testing.T) {
	c, f, _ := client(t, "")
	start := time.UnixMilli(1_700_000_000_000)
	c.Set(&Activity{
		Title:  "Alice",
		Artist: "bassvictim",
		Album:  "Forever",
		Cover:  "https://avatars.yandex.net/x/400x400",
		Link:   "https://music.yandex.ru/album/1/track/2",
		Start:  start,
		End:    start.Add(125 * time.Second),
	})
	a := next(t, f)
	if a["details"] != "Alice" || a["state"] != "bassvictim" || a["type"] != float64(listenType) {
		t.Fatalf("activity = %v", a)
	}
	ts := a["timestamps"].(map[string]any)
	if ts["start"] != float64(start.UnixMilli()) || ts["end"] != float64(start.Add(125*time.Second).UnixMilli()) {
		t.Fatalf("timestamps = %v", ts)
	}
	assets := a["assets"].(map[string]any)
	if assets["large_image"] != "https://avatars.yandex.net/x/400x400" || assets["large_text"] != "Forever" {
		t.Fatalf("assets = %v", assets)
	}
	if b := a["buttons"].([]any); len(b) != 1 || b[0].(map[string]any)["url"] != "https://music.yandex.ru/album/1/track/2" {
		t.Fatalf("buttons = %v", b)
	}

	c.Set(nil)
	if a := next(t, f); a != nil {
		t.Fatalf("после очистки activity = %v", a)
	}
}

func TestRejectedIsLogged(t *testing.T) {
	c, f, logs := client(t, "bad activity")
	c.Set(&Activity{Title: "A", Artist: "B"})
	a := next(t, f)
	if a["details"] != "A​" {
		t.Fatalf("короткий текст не дополнен: %q", a["details"])
	}
	timeout := time.After(2 * time.Second)
	for {
		select {
		case s := <-logs:
			if strings.Contains(s, "bad activity") {
				return
			}
		case <-timeout:
			t.Fatal("ошибка не попала в лог")
		}
	}
}

func TestDisabledWithoutID(t *testing.T) {
	c := New("", nil)
	if c.Enabled() {
		t.Fatal("клиент без ID включён")
	}
	c.Set(&Activity{Title: "x"})
}

func TestTextLimits(t *testing.T) {
	long := strings.Repeat("я", 200)
	if got := []rune(text(long)); len(got) != 128 {
		t.Fatalf("длина %d", len(got))
	}
}
