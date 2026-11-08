package yam

import (
	"bufio"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type ProgressFunc func(done, total int64)

type Result struct {
	Path    string
	Format  string
	Size    int64
	Skipped bool
}

var audioExts = []string{".flac", ".mp3", ".m4a"}

func Existing(base string) string {
	for _, ext := range audioExts {
		if st, err := os.Stat(base + ext); err == nil && st.Size() > 0 {
			return base + ext
		}
	}
	return ""
}

var errEmpty = errors.New("аудио скачалось пустым, ссылка устарела")

func (s *Session) DownloadTrack(ctx context.Context, t Track, base string, q Quality, progress ProgressFunc) (Result, error) {
	if p := Existing(base); p != "" {
		st, _ := os.Stat(p)
		return Result{Path: p, Skipped: true, Size: st.Size()}, nil
	}
	if !t.Available {
		return Result{}, errors.New("трек недоступен в каталоге")
	}
	if err := os.MkdirAll(filepath.Dir(base), 0o755); err != nil {
		return Result{}, err
	}

	var lastErr error
	for attempt := range 3 {
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(attempt) * 1500 * time.Millisecond):
			case <-ctx.Done():
				return Result{}, ctx.Err()
			}
		}
		res, err := s.downloadOnce(ctx, t, base, q, progress)
		if err == nil {
			return res, nil
		}
		if ctx.Err() != nil {
			return Result{}, ctx.Err()
		}
		if !retryable(err) {
			return Result{}, err
		}
		lastErr = err
	}
	return Result{}, lastErr
}

func retryable(err error) bool {
	if errors.Is(err, ErrUnauthorized) {
		return false
	}
	var ae *APIError
	if errors.As(err, &ae) {
		return ae.Status >= 500 || ae.Status == http.StatusTooManyRequests ||
			ae.Status == http.StatusRequestTimeout || ae.Status == http.StatusForbidden
	}
	var ne net.Error
	return errors.Is(err, errEmpty) || errors.Is(err, io.ErrUnexpectedEOF) || errors.As(err, &ne)
}

func (s *Session) downloadOnce(ctx context.Context, t Track, base string, q Quality, progress ProgressFunc) (Result, error) {
	src, err := s.audioSource(ctx, t.ID, q)
	if err != nil {
		return Result{}, err
	}

	part := base + ".part"
	n, err := s.stream(ctx, src, part, progress)
	if err != nil {
		os.Remove(part)
		return Result{}, err
	}
	defer os.Remove(part)

	tags := tagsFor(t, s.cover(ctx, t.Cover))
	in, err := os.Open(part)
	if err != nil {
		return Result{}, err
	}
	defer in.Close()

	var head [12]byte
	_, _ = in.ReadAt(head[:], 0)
	switch {
	case string(head[4:8]) == "ftyp":
		var format string
		path, err := writeVia(base+".flac", func(w io.Writer) (err error) {
			format, err = remuxFLAC(in, n, w, tags)
			return err
		})
		if errors.Is(err, errNotFLAC) {

			in.Close()
			dst := base + ".m4a"
			if err := os.Rename(part, dst); err != nil {
				return Result{}, err
			}
			return Result{Path: dst, Format: "AAC", Size: n}, nil
		}
		if err != nil {
			return Result{}, fmt.Errorf("сборка FLAC: %w", err)
		}
		return result(path, format), nil

	case string(head[:4]) == "fLaC":
		var format string
		path, err := writeVia(base+".flac", func(w io.Writer) (err error) {
			format, err = retagFLAC(in, n, w, tags)
			return err
		})
		if err != nil {
			return Result{}, fmt.Errorf("теги FLAC: %w", err)
		}
		return result(path, format), nil

	default:
		path, err := writeVia(base+".mp3", func(w io.Writer) error {
			return tagMP3(in, n, w, tags)
		})
		if err != nil {
			return Result{}, fmt.Errorf("теги MP3: %w", err)
		}
		format := "MP3"
		if src.Bitrate > 0 {
			format = fmt.Sprintf("MP3 %d", src.Bitrate)
		}
		return result(path, format), nil
	}
}

func result(path, format string) Result {
	r := Result{Path: path, Format: format}
	if st, err := os.Stat(path); err == nil {
		r.Size = st.Size()
	}
	return r
}

func (s *Session) stream(ctx context.Context, src source, dst string, progress ProgressFunc) (int64, error) {
	req, err := s.newRequest(ctx, http.MethodGet, src.URL, nil, "", false)
	if err != nil {
		return 0, err
	}
	resp, err := s.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, &APIError{Status: resp.StatusCode}
	}

	var body io.Reader = &countingReader{r: resp.Body, total: resp.ContentLength, fn: progress}
	if src.Key != "" {
		key, err := hex.DecodeString(src.Key)
		if err != nil {
			return 0, fmt.Errorf("ключ расшифровки: %w", err)
		}
		block, err := aes.NewCipher(key)
		if err != nil {
			return 0, fmt.Errorf("ключ расшифровки: %w", err)
		}

		body = cipher.StreamReader{S: cipher.NewCTR(block, make([]byte, aes.BlockSize)), R: body}
	}

	f, err := os.Create(dst)
	if err != nil {
		return 0, err
	}
	n, err := io.CopyBuffer(f, body, make([]byte, 256<<10))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return n, err
	}
	if resp.ContentLength > 0 && n != resp.ContentLength {
		return n, io.ErrUnexpectedEOF
	}
	if n < 1024 {
		return n, errEmpty
	}
	return n, nil
}

func writeVia(dst string, fill func(io.Writer) error) (string, error) {
	tmp := dst + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return "", err
	}
	w := bufio.NewWriterSize(f, 1<<20)
	err = fill(w)
	if err == nil {
		err = w.Flush()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, dst)
	}
	if err != nil {
		os.Remove(tmp)
		return "", err
	}
	return dst, nil
}

type countingReader struct {
	r     io.Reader
	done  int64
	total int64
	fn    ProgressFunc
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if n > 0 {
		c.done += int64(n)
		if c.fn != nil {
			c.fn(c.done, c.total)
		}
	}
	return n, err
}

const coverSize = "1000x1000"

type coverCache struct {
	mu sync.Mutex
	m  map[string]*coverEntry
}

const coverAttempts = 3

type coverEntry struct {
	turn  chan struct{}
	data  []byte
	fails int
}

func (s *Session) cover(ctx context.Context, uri string) []byte {
	if uri == "" {
		return nil
	}
	s.covers.mu.Lock()
	if s.covers.m == nil || len(s.covers.m) > 256 {
		s.covers.m = map[string]*coverEntry{}
	}
	e := s.covers.m[uri]
	if e == nil {
		e = &coverEntry{turn: make(chan struct{}, 1)}
		s.covers.m[uri] = e
	}
	s.covers.mu.Unlock()

	select {
	case e.turn <- struct{}{}:
	case <-ctx.Done():
		return nil
	}
	defer func() { <-e.turn }()
	if e.data != nil || e.fails >= coverAttempts {
		return e.data
	}
	b, err := s.fetch(ctx, http.MethodGet, CoverURL(uri, coverSize), nil, false)
	switch {
	case err == nil && len(b) > 0:
		e.data = b
	case ctx.Err() == nil:
		e.fails++
	}
	return e.data
}

func (s *Session) SaveCover(ctx context.Context, uri, dir string) {
	dst := filepath.Join(dir, "cover.jpg")
	if _, err := os.Stat(dst); err == nil {
		return
	}
	if b := s.cover(ctx, uri); len(b) > 0 {
		if os.MkdirAll(dir, 0o755) == nil {
			_ = os.WriteFile(dst, b, 0o644)
		}
	}
}
