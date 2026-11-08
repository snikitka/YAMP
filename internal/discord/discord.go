package discord

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	opHandshake = 0
	opFrame     = 1
	opClose     = 2
	opPing      = 3
	opPong      = 4

	maxFrame   = 64 << 10
	retryAfter = 15 * time.Second
	listenType = 2
	buttonText = "Слушать в Яндекс Музыке"
)

type Activity struct {
	Title, Artist, Album, Cover, Link string
	Start, End                        time.Time
}

type Client struct {
	id      string
	mu      sync.Mutex
	updates chan *Activity
	dial    func() (io.ReadWriteCloser, error)
	log     func(string)
}

func New(id string, log func(string)) *Client {
	c := &Client{id: id, updates: make(chan *Activity, 1), dial: dial, log: log}
	if id != "" {
		go c.run()
	}
	return c
}

func (c *Client) Enabled() bool { return c.id != "" }

func (c *Client) Set(a *Activity) {
	if c.id == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	select {
	case <-c.updates:
	default:
	}
	c.updates <- a
}

func (c *Client) run() {
	var (
		conn  io.ReadWriteCloser
		want  *Activity
		sent  = true
		wait  <-chan time.Time
		nonce  int
		failed bool
	)
	for {
		select {
		case a := <-c.updates:
			want, sent = a, false
		case <-wait:
			wait = nil
		}
		if sent || wait != nil {
			continue
		}
		if conn == nil {
			if want == nil {
				sent = true
				continue
			}
			var err error
			if conn, err = c.connect(); err != nil {
				if !failed && c.log != nil {
					c.log("Discord недоступен: " + err.Error())
				}
				failed = true
				conn, wait = nil, time.After(retryAfter)
				continue
			}
			failed = false
			if c.log != nil {
				c.log("Discord подключён")
			}
		}
		nonce++
		err := setActivity(conn, want, nonce)
		var bad *rejected
		switch {
		case err == nil:
			sent = true
		case errors.As(err, &bad):
			sent = true
			if c.log != nil {
				c.log("Discord отклонил статус: " + bad.msg)
			}
		default:
			conn.Close()
			conn, wait = nil, time.After(time.Second)
		}
	}
}

func (c *Client) connect() (io.ReadWriteCloser, error) {
	conn, err := c.dial()
	if err != nil {
		return nil, err
	}
	if err := handshake(conn, c.id); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func handshake(rw io.ReadWriter, id string) error {
	if err := writeFrame(rw, opHandshake, map[string]any{"v": 1, "client_id": id}); err != nil {
		return err
	}
	for {
		op, body, err := readFrame(rw)
		if err != nil {
			return err
		}
		switch op {
		case opClose:
			return fmt.Errorf("discord закрыл соединение: %s", body)
		case opPing:
			if err := writeRaw(rw, opPong, body); err != nil {
				return err
			}
		case opFrame:
			var m struct {
				Evt string `json:"evt"`
			}
			if json.Unmarshal(body, &m) == nil && m.Evt == "READY" {
				return nil
			}
		}
	}
}

type rejected struct{ msg string }

func (r *rejected) Error() string { return r.msg }

func setActivity(rw io.ReadWriter, a *Activity, nonce int) error {
	id := fmt.Sprint(nonce)
	args := map[string]any{"pid": os.Getpid()}
	if a != nil {
		args["activity"] = shape(a)
	}
	if err := writeFrame(rw, opFrame, map[string]any{"cmd": "SET_ACTIVITY", "args": args, "nonce": id}); err != nil {
		return err
	}
	for {
		op, body, err := readFrame(rw)
		if err != nil {
			return err
		}
		switch op {
		case opClose:
			return fmt.Errorf("discord закрыл соединение: %s", body)
		case opPing:
			if err := writeRaw(rw, opPong, body); err != nil {
				return err
			}
		case opFrame:
			var m struct {
				Evt   string `json:"evt"`
				Nonce string `json:"nonce"`
				Data  struct {
					Message string `json:"message"`
				} `json:"data"`
			}
			if json.Unmarshal(body, &m) != nil || m.Nonce != id {
				continue
			}
			if m.Evt == "ERROR" {
				return &rejected{m.Data.Message}
			}
			return nil
		}
	}
}

func shape(a *Activity) map[string]any {
	act := map[string]any{
		"type":    listenType,
		"details": text(a.Title),
		"state":   text(a.Artist),
	}
	if !a.Start.IsZero() {
		ts := map[string]any{"start": a.Start.UnixMilli()}
		if a.End.After(a.Start) {
			ts["end"] = a.End.UnixMilli()
		}
		act["timestamps"] = ts
	}
	if a.Cover != "" {
		assets := map[string]any{"large_image": a.Cover}
		if a.Album != "" {
			assets["large_text"] = text(a.Album)
		}
		act["assets"] = assets
	}
	if strings.HasPrefix(a.Link, "https://") {
		act["buttons"] = []map[string]string{{"label": buttonText, "url": a.Link}}
	}
	return act
}

func text(s string) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > 128 {
		r := []rune(s)
		s = strings.TrimSpace(string(r[:127])) + "…"
	}
	for utf8.RuneCountInString(s) < 2 {
		s += "​"
	}
	return s
}

func writeFrame(w io.Writer, op uint32, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return writeRaw(w, op, body)
}

func writeRaw(w io.Writer, op uint32, body []byte) error {
	buf := make([]byte, 8+len(body))
	binary.LittleEndian.PutUint32(buf, op)
	binary.LittleEndian.PutUint32(buf[4:], uint32(len(body)))
	copy(buf[8:], body)
	_, err := w.Write(buf)
	return err
}

func readFrame(r io.Reader) (uint32, []byte, error) {
	var head [8]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return 0, nil, err
	}
	op := binary.LittleEndian.Uint32(head[:])
	n := binary.LittleEndian.Uint32(head[4:])
	if n > maxFrame {
		return 0, nil, fmt.Errorf("слишком большой кадр discord: %d", n)
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		return 0, nil, err
	}
	return op, body, nil
}
