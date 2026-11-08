package remote

import (
	"bufio"
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"
)

const dialTimeout = 5 * time.Second

var (
	ErrFingerprint = errors.New("сертификат компьютера не совпадает с тем, что был при связывании")
	ErrNoAddress   = errors.New("неизвестен адрес компьютера")
)

type Conn struct {
	c   *tls.Conn
	r   *bufio.Reader
	wmu sync.Mutex
}

func pinned(fp string) *tls.Config {
	return &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true,
		VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return ErrFingerprint
			}
			got := Fingerprint(cs.PeerCertificates[0].Raw)
			if subtle.ConstantTimeCompare([]byte(got), []byte(fp)) != 1 {
				return ErrFingerprint
			}
			return nil
		},
	}
}

func Dial(ctx context.Context, addrs []string, fp string) (*Conn, error) {
	if len(addrs) == 0 {
		return nil, ErrNoAddress
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type result struct {
		c   *tls.Conn
		err error
	}
	results := make(chan result, len(addrs))
	d := &tls.Dialer{NetDialer: &net.Dialer{Timeout: dialTimeout, KeepAlive: pingEvery}, Config: pinned(fp)}
	for _, a := range addrs {
		go func() {
			c, err := d.DialContext(ctx, "tcp", a)
			if err != nil {
				results <- result{err: err}
				return
			}
			results <- result{c: c.(*tls.Conn)}
		}()
	}
	var firstErr error
	var won *tls.Conn
	for range addrs {
		r := <-results
		switch {
		case r.c != nil && won == nil:
			won = r.c
			cancel()
		case r.c != nil:
			r.c.Close()
		case errors.Is(r.err, ErrFingerprint):
			firstErr = ErrFingerprint
		case firstErr == nil:
			firstErr = r.err
		}
	}
	if won == nil {
		return nil, firstErr
	}
	return &Conn{c: won, r: bufio.NewReaderSize(won, 64<<10)}, nil
}

func (c *Conn) Hello(h Hello) (Welcome, error) {
	_ = c.c.SetDeadline(time.Now().Add(helloTimeout))
	defer c.c.SetDeadline(time.Time{})
	if err := c.Send(mustJSON(h)); err != nil {
		return Welcome{}, err
	}
	line, err := readLine(c.r, helloMax)
	if err != nil {
		return Welcome{}, err
	}
	var w Welcome
	if err := json.Unmarshal(line, &w); err != nil {
		return Welcome{}, err
	}
	return w, nil
}

func (c *Conn) Read() ([]byte, error) {
	for {
		_ = c.c.SetReadDeadline(time.Now().Add(readTimeout))
		line, err := readLine(c.r, 64<<20)
		if err != nil {
			return nil, err
		}
		if len(line) > 0 && string(line) != string(pingLine) {
			return line, nil
		}
	}
}

func (c *Conn) Send(line []byte) error {
	framed := make([]byte, len(line)+1)
	copy(framed, line)
	framed[len(line)] = '\n'
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_ = c.c.SetWriteDeadline(time.Now().Add(writeTimeout))
	_, err := c.c.Write(framed)
	return err
}

func (c *Conn) Host() string {
	if a, ok := c.c.RemoteAddr().(*net.TCPAddr); ok {
		return a.IP.String()
	}
	return ""
}

func (c *Conn) Close() error {
	return c.c.Close()
}

func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
