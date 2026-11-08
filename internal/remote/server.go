package remote

import (
	"bufio"
	"bytes"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"
)

const (
	OpPair = "pair"
	OpAuth = "auth"

	ErrSecret   = "secret"
	ErrUnpaired = "unpaired"
	ErrStore    = "store"
	ErrOp       = "op"

	helloTimeout = 10 * time.Second
	writeTimeout = 10 * time.Second
	pingEvery    = 15 * time.Second
	readTimeout  = 3 * pingEvery
	helloMax     = 4 << 10
	commandMax   = 64 << 10
	peerBacklog  = 256
	maxMisses    = 5
)

var (
	errTooLong = errors.New("слишком длинная строка")
	pingLine   = []byte(`{"type":"ping"}`)
)

type Hello struct {
	Op     string `json:"op"`
	ID     string `json:"id"`
	Name   string `json:"name"`
	Secret string `json:"secret,omitempty"`
	Key    string `json:"key,omitempty"`
}

type Welcome struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	ID    string `json:"id,omitempty"`
	Name  string `json:"name,omitempty"`
	Key   string `json:"key,omitempty"`
}

type Host interface {
	Authorize(id, key string) bool
	Pair(id, name string) (key string, err error)
	Snapshot() [][]byte
	Command(id string, line []byte)
	Changed()
}

type Server struct {
	id, name string
	ln       net.Listener
	tls      *tls.Config
	host     Host

	mu      sync.Mutex
	secret  string
	expires time.Time
	misses  int
	peers   map[*peer]struct{}
	closed  bool
}

type peer struct {
	id   string
	conn net.Conn
	out  chan []byte
	done chan struct{}
	once sync.Once
}

func (p *peer) close() {
	p.once.Do(func() {
		close(p.done)
		p.conn.Close()
	})
}

func (p *peer) send(line []byte) {
	select {
	case <-p.done:
	case p.out <- line:
	default:
		p.close()
	}
}

func NewServer(ln net.Listener, ident *Identity, id, name string, host Host) *Server {
	return &Server{
		id: id, name: name, ln: ln, host: host,
		tls:   &tls.Config{Certificates: []tls.Certificate{ident.Cert}, MinVersion: tls.VersionTLS13},
		peers: map[*peer]struct{}{},
	}
}

func (s *Server) Port() int {
	if a, ok := s.ln.Addr().(*net.TCPAddr); ok {
		return a.Port
	}
	return 0
}

func (s *Server) Serve() {
	for {
		raw, err := s.ln.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				return
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go s.handle(raw)
	}
}

func (s *Server) Close() {
	s.mu.Lock()
	s.closed = true
	peers := s.peers
	s.peers = map[*peer]struct{}{}
	s.mu.Unlock()
	s.ln.Close()
	for p := range peers {
		p.close()
	}
}

func (s *Server) NewSecret(ttl time.Duration) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.secret = RandomToken(18)
	s.expires = time.Now().Add(ttl)
	s.misses = 0
	return s.secret
}

func (s *Server) ClearSecret() {
	s.mu.Lock()
	s.secret = ""
	s.mu.Unlock()
}

func (s *Server) Pairing() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.secret != "" && time.Now().Before(s.expires)
}

func (s *Server) takeSecret(secret string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.secret == "" || time.Now().After(s.expires) {
		return false
	}
	if subtle.ConstantTimeCompare([]byte(secret), []byte(s.secret)) == 1 {
		s.secret = ""
		return true
	}
	s.misses++
	if s.misses >= maxMisses {
		s.secret = ""
	}
	return false
}

func (s *Server) Broadcast(line []byte) {
	s.mu.Lock()
	peers := make([]*peer, 0, len(s.peers))
	for p := range s.peers {
		peers = append(peers, p)
	}
	s.mu.Unlock()
	for _, p := range peers {
		p.send(line)
	}
}

func (s *Server) Kick(id string) {
	s.mu.Lock()
	var gone []*peer
	for p := range s.peers {
		if p.id == id {
			gone = append(gone, p)
		}
	}
	s.mu.Unlock()
	for _, p := range gone {
		p.close()
	}
}

func (s *Server) Online() map[string]bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]bool{}
	for p := range s.peers {
		out[p.id] = true
	}
	return out
}

func (s *Server) welcome(h Hello) Welcome {
	w := Welcome{ID: s.id, Name: s.name}
	switch h.Op {
	case OpPair:
		if h.ID == "" || !s.takeSecret(h.Secret) {
			w.Error = ErrSecret
			return w
		}
		key, err := s.host.Pair(h.ID, h.Name)
		if err != nil {
			w.Error = ErrStore
			return w
		}
		w.OK, w.Key = true, key
	case OpAuth:
		if h.ID == "" || h.Key == "" || !s.host.Authorize(h.ID, h.Key) {
			w.Error = ErrUnpaired
			return w
		}
		w.OK = true
	default:
		w.Error = ErrOp
	}
	return w
}

func (s *Server) handle(raw net.Conn) {
	conn := tls.Server(raw, s.tls)
	_ = conn.SetDeadline(time.Now().Add(helloTimeout))
	r := bufio.NewReaderSize(conn, 4<<10)
	line, err := readLine(r, helloMax)
	if err != nil {
		conn.Close()
		return
	}
	var h Hello
	if json.Unmarshal(line, &h) != nil {
		conn.Close()
		return
	}
	w := s.welcome(h)
	reply, _ := json.Marshal(w)
	if _, err := conn.Write(append(reply, '\n')); err != nil || !w.OK {
		conn.Close()
		return
	}
	_ = conn.SetDeadline(time.Time{})

	p := &peer{id: h.ID, conn: conn, out: make(chan []byte, peerBacklog), done: make(chan struct{})}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		conn.Close()
		return
	}
	s.peers[p] = struct{}{}
	s.mu.Unlock()
	go s.write(p)
	s.host.Changed()
	for _, l := range s.host.Snapshot() {
		p.send(l)
	}
	for {
		line, err := readLine(r, commandMax)
		if err != nil {
			break
		}
		if len(line) > 0 {
			s.host.Command(h.ID, line)
		}
	}
	p.close()
	s.mu.Lock()
	_, known := s.peers[p]
	delete(s.peers, p)
	s.mu.Unlock()
	if known {
		s.host.Changed()
	}
}

func (s *Server) write(p *peer) {
	t := time.NewTicker(pingEvery)
	defer t.Stop()
	for {
		var line []byte
		select {
		case <-p.done:
			return
		case line = <-p.out:
		case <-t.C:
			line = pingLine
		}
		framed := make([]byte, len(line)+1)
		copy(framed, line)
		framed[len(line)] = '\n'
		_ = p.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
		if _, err := p.conn.Write(framed); err != nil {
			p.close()
			return
		}
	}
}

func readLine(r *bufio.Reader, max int) ([]byte, error) {
	var buf []byte
	for {
		chunk, err := r.ReadSlice('\n')
		buf = append(buf, chunk...)
		if len(buf) > max {
			return nil, errTooLong
		}
		if err == nil {
			return bytes.TrimRight(buf, "\r\n"), nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}
