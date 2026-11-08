package gui

import (
	"crypto/rand"
	"encoding/hex"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"yamp/internal/yam"
)

type streamServer struct {
	streamer *yam.Streamer

	once sync.Once
	base string
	err  error
}

func newStreamServer() *streamServer {
	return &streamServer{streamer: yam.NewStreamer()}
}

func (s *streamServer) start() (string, error) {
	s.once.Do(func() {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			s.err = err
			return
		}
		var b [16]byte
		_, _ = rand.Read(b[:])
		prefix := "/" + hex.EncodeToString(b[:])
		mux := http.NewServeMux()
		mux.Handle(prefix+"/", http.StripPrefix(prefix, s.streamer))
		srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
		go func() { _ = srv.Serve(ln) }()
		s.base = "http://" + ln.Addr().String() + prefix
	})
	return s.base, s.err
}

func (s *streamServer) url(trackID string, q yam.Quality) (string, error) {
	base, err := s.start()
	if err != nil {
		return "", err
	}
	return base + "/" + url.PathEscape(trackID) + "?q=" + url.QueryEscape(string(q)), nil
}
