package yam

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const sourceTTL = 10 * time.Minute

var trackIDRe = regexp.MustCompile(`^[0-9A-Za-z-]{1,64}$`)

type Format struct {
	Codec    string
	Bitrate  int
	Lossless bool
}

func (f Format) String() string {
	name := strings.ToUpper(strings.TrimSuffix(f.Codec, "-mp4"))
	if f.Lossless {
		return "FLAC"
	}
	if f.Bitrate > 0 {
		return fmt.Sprintf("%s %d", name, f.Bitrate)
	}
	return name
}

type Streamer struct {
	mu     sync.Mutex
	client *Client
	cache  map[string]*sourceEntry
}

type sourceEntry struct {
	ready chan struct{}
	src   source
	err   error
	at    time.Time
}

func NewStreamer() *Streamer {
	return &Streamer{cache: map[string]*sourceEntry{}}
}

func (s *Streamer) SetClient(c *Client) {
	s.mu.Lock()
	s.client = c
	s.cache = map[string]*sourceEntry{}
	s.mu.Unlock()
}

func (s *Streamer) Prepare(ctx context.Context, trackID string, q Quality) (Format, error) {
	src, err := s.source(ctx, trackID, q, false)
	if err != nil {
		return Format{}, err
	}
	return formatOf(src), nil
}

func (s *Streamer) Check(ctx context.Context, trackID string, q Quality) error {
	_, err := s.source(ctx, trackID, q, true)
	return err
}

func Offline(err error) bool {
	if err == nil {
		return false
	}
	var ue *url.Error
	var ne net.Error
	return errors.As(err, &ue) || errors.As(err, &ne) || errors.Is(err, context.DeadlineExceeded)
}

func formatOf(src source) Format {
	return Format{Codec: src.Codec, Bitrate: src.Bitrate, Lossless: isFlacCodec(src.Codec)}
}

func (s *Streamer) source(ctx context.Context, trackID string, q Quality, fresh bool) (source, error) {
	key := trackID + "/" + string(q)
	s.mu.Lock()
	c := s.client
	if c == nil {
		s.mu.Unlock()
		return source{}, ErrUnauthorized
	}
	e := s.cache[key]
	if e != nil && !fresh {
		select {
		case <-e.ready:
			if e.err != nil || time.Since(e.at) > sourceTTL {
				e = nil
			}
		default:
		}
	} else {
		e = nil
	}
	if e == nil {
		if len(s.cache) > 64 {
			s.cache = map[string]*sourceEntry{}
		}
		e = &sourceEntry{ready: make(chan struct{})}
		s.cache[key] = e
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			e.src, e.err = c.audioSource(ctx, trackID, q)
			e.at = time.Now()
			close(e.ready)
		}()
	}
	s.mu.Unlock()
	select {
	case <-e.ready:
		return e.src, e.err
	case <-ctx.Done():
		return source{}, ctx.Err()
	}
}

func (s *Streamer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	id := strings.Trim(r.URL.Path, "/")
	if !trackIDRe.MatchString(id) {
		http.NotFound(w, r)
		return
	}
	q := Quality(r.URL.Query().Get("q"))
	switch q {
	case Lossless, MP3, Low:
	default:
		q = Lossless
	}
	ctx := r.Context()
	rng := r.Header.Get("Range")

	src, resp, err := s.open(ctx, id, q, rng, false)
	if err == nil && expired(resp.StatusCode) {
		resp.Body.Close()
		src, resp, err = s.open(ctx, id, q, rng, true)
	}
	if err != nil {
		streamError(w, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		streamError(w, &APIError{Status: resp.StatusCode})
		return
	}

	h := w.Header()
	h.Set("Content-Type", contentType(src.Codec))
	h.Set("Accept-Ranges", "bytes")
	h.Set("Cache-Control", "no-store")
	if v := resp.Header.Get("Content-Length"); v != "" {
		h.Set("Content-Length", v)
	}
	if v := resp.Header.Get("Content-Range"); v != "" {
		h.Set("Content-Range", v)
	}
	w.WriteHeader(resp.StatusCode)
	if r.Method == http.MethodHead {
		return
	}

	var body io.Reader = resp.Body
	if src.Key != "" {
		offset := int64(0)
		if resp.StatusCode == http.StatusPartialContent {
			offset = rangeStart(resp.Header.Get("Content-Range"))
		}
		stream, err := ctrAt(src.Key, offset)
		if err != nil {
			return
		}
		body = cipher.StreamReader{S: stream, R: resp.Body}
	}
	_, _ = io.CopyBuffer(w, body, make([]byte, 64<<10))
}

func (s *Streamer) open(ctx context.Context, id string, q Quality, rng string, fresh bool) (source, *http.Response, error) {
	src, err := s.source(ctx, id, q, fresh)
	if err != nil {
		return source{}, nil, err
	}
	s.mu.Lock()
	c := s.client
	s.mu.Unlock()
	if c == nil {
		return source{}, nil, ErrUnauthorized
	}
	req, err := c.newRequest(ctx, http.MethodGet, src.URL, nil, "", false)
	if err != nil {
		return source{}, nil, err
	}
	if rng != "" {
		req.Header.Set("Range", rng)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return source{}, nil, err
	}
	return src, resp, nil
}

func expired(status int) bool {
	return status == http.StatusForbidden || status == http.StatusGone || status == http.StatusNotFound
}

func streamError(w http.ResponseWriter, err error) {
	status := http.StatusBadGateway
	var ae *APIError
	switch {
	case errors.Is(err, ErrUnauthorized):
		status = http.StatusUnauthorized
	case errors.Is(err, context.Canceled):
		return
	case errors.As(err, &ae) && ae.Status == http.StatusRequestedRangeNotSatisfiable:
		status = ae.Status
	}
	http.Error(w, err.Error(), status)
}

func contentType(codec string) string {
	switch strings.ToLower(codec) {
	case "flac":
		return "audio/flac"
	case "flac-mp4", "aac-mp4", "he-aac-mp4":
		return "audio/mp4"
	case "aac", "he-aac":
		return "audio/aac"
	}
	return "audio/mpeg"
}

func rangeStart(contentRange string) int64 {
	v, ok := strings.CutPrefix(strings.TrimSpace(contentRange), "bytes ")
	if !ok {
		return 0
	}
	start, _, _ := strings.Cut(v, "-")
	n, err := strconv.ParseInt(strings.TrimSpace(start), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func ctrAt(hexKey string, offset int64) (cipher.Stream, error) {
	key, err := hex.DecodeString(hexKey)
	if err != nil {
		return nil, fmt.Errorf("ключ расшифровки: %w", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("ключ расшифровки: %w", err)
	}
	iv := make([]byte, aes.BlockSize)
	binary.BigEndian.PutUint64(iv[8:], uint64(offset/aes.BlockSize))
	stream := cipher.NewCTR(block, iv)
	if skip := offset % aes.BlockSize; skip > 0 {
		pad := make([]byte, skip)
		stream.XORKeyStream(pad, pad)
	}
	return stream, nil
}
