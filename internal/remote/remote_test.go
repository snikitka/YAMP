package remote

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeHost struct {
	mu       sync.Mutex
	store    Store
	commands []string
	changed  int
	pairErr  error
}

func (h *fakeHost) Authorize(id, key string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.store.Authorize(id, key)
}

func (h *fakeHost) Pair(id, name string) (string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.pairErr != nil {
		return "", h.pairErr
	}
	return h.store.AddClient(id, name), nil
}

func (h *fakeHost) Snapshot() [][]byte { return [][]byte{[]byte(`{"type":"player","track":{"id":"7"}}`)} }

func (h *fakeHost) Command(id string, line []byte) {
	h.mu.Lock()
	h.commands = append(h.commands, id+" "+string(line))
	h.mu.Unlock()
}

func (h *fakeHost) Changed() {
	h.mu.Lock()
	h.changed++
	h.mu.Unlock()
}

func (h *fakeHost) seen() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.commands...)
}

func startServer(t *testing.T) (*Server, *Identity, *fakeHost, string) {
	t.Helper()
	ident, err := LoadIdentity(filepath.Join(t.TempDir(), "remote.pem"))
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	host := &fakeHost{store: Store{ID: "pc"}}
	srv := NewServer(ln, ident, "pc", "Комп", host)
	go srv.Serve()
	t.Cleanup(srv.Close)
	return srv, ident, host, ln.Addr().String()
}

func dial(t *testing.T, addr, fp string) *Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, []string{addr}, fp)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func eventually(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal(what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestIdentityPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "remote.pem")
	a, err := LoadIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	b, err := LoadIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	if a.Fingerprint != b.Fingerprint || a.Fingerprint == "" {
		t.Fatalf("отпечаток сменился между запусками: %q и %q", a.Fingerprint, b.Fingerprint)
	}
	if a.Fingerprint != Fingerprint(a.Cert.Certificate[0]) {
		t.Fatal("отпечаток не совпадает с сертификатом")
	}
}

func TestPairThenAuth(t *testing.T) {
	srv, ident, host, addr := startServer(t)
	secret := srv.NewSecret(time.Minute)

	c := dial(t, addr, ident.Fingerprint)
	w, err := c.Hello(Hello{Op: OpPair, ID: "phone", Name: "Пиксель", Secret: secret})
	if err != nil || !w.OK || w.Key == "" || w.ID != "pc" || w.Name != "Комп" {
		t.Fatalf("связывание: %+v, %v", w, err)
	}
	line, err := c.Read()
	if err != nil || !strings.Contains(string(line), `"id":"7"`) {
		t.Fatalf("ждали снимок плеера, пришло %q, %v", line, err)
	}
	if err := c.Send([]byte(`{"cmd":"playerNext"}`)); err != nil {
		t.Fatal(err)
	}
	eventually(t, "команда не дошла", func() bool { return len(host.seen()) == 1 })
	if got := host.seen()[0]; got != `phone {"cmd":"playerNext"}` {
		t.Fatalf("команда = %q", got)
	}
	srv.Broadcast([]byte(`{"type":"mark"}`))
	if line, err := c.Read(); err != nil || string(line) != `{"type":"mark"}` {
		t.Fatalf("рассылка: %q, %v", line, err)
	}
	if !srv.Online()["phone"] {
		t.Fatal("телефон не в сети")
	}
	c.Close()
	eventually(t, "сервер не заметил отключение", func() bool { return !srv.Online()["phone"] })

	again := dial(t, addr, ident.Fingerprint)
	w, err = again.Hello(Hello{Op: OpAuth, ID: "phone", Key: w.Key})
	if err != nil || !w.OK {
		t.Fatalf("вход по ключу: %+v, %v", w, err)
	}
	if _, err := again.Read(); err != nil {
		t.Fatal(err)
	}
}

func TestSecretSingleUse(t *testing.T) {
	srv, ident, _, addr := startServer(t)
	secret := srv.NewSecret(time.Minute)
	first := dial(t, addr, ident.Fingerprint)
	if w, err := first.Hello(Hello{Op: OpPair, ID: "a", Secret: secret}); err != nil || !w.OK {
		t.Fatalf("первое связывание: %+v, %v", w, err)
	}
	second := dial(t, addr, ident.Fingerprint)
	if w, err := second.Hello(Hello{Op: OpPair, ID: "b", Secret: secret}); err != nil || w.OK || w.Error != ErrSecret {
		t.Fatalf("секрет сработал дважды: %+v, %v", w, err)
	}
}

func TestSecretGuessing(t *testing.T) {
	srv, _, _, _ := startServer(t)
	secret := srv.NewSecret(time.Minute)
	for range maxMisses {
		if srv.takeSecret("wrong") {
			t.Fatal("подошёл чужой секрет")
		}
	}
	if srv.takeSecret(secret) {
		t.Fatal("после серии неверных попыток секрет должен сгореть")
	}

	secret = srv.NewSecret(-time.Second)
	if srv.takeSecret(secret) {
		t.Fatal("сработал просроченный секрет")
	}
}

func TestRejectsUnpaired(t *testing.T) {
	srv, ident, host, addr := startServer(t)
	_ = srv.NewSecret(time.Minute)
	host.store.AddClient("phone", "Пиксель")

	cases := []Hello{
		{Op: OpAuth, ID: "phone", Key: "guess"},
		{Op: OpAuth, ID: "stranger", Key: "guess"},
		{Op: OpAuth, ID: "phone"},
		{Op: OpPair, ID: "stranger", Secret: "guess"},
		{Op: "command", ID: "phone"},
	}
	for _, h := range cases {
		c := dial(t, addr, ident.Fingerprint)
		w, err := c.Hello(h)
		if err != nil || w.OK || w.Key != "" {
			t.Fatalf("%+v пустили: %+v, %v", h, w, err)
		}
		_ = c.Send([]byte(`{"cmd":"playerNext"}`))
		if _, err := c.Read(); err == nil {
			t.Fatalf("%+v: соединение должно закрыться", h)
		}
	}
	if got := host.seen(); len(got) != 0 {
		t.Fatalf("команды от чужих дошли: %v", got)
	}
	if len(srv.Online()) != 0 {
		t.Fatal("чужой телефон в списке подключённых")
	}
}

func TestPinning(t *testing.T) {
	_, _, _, addr := startServer(t)
	other, err := LoadIdentity(filepath.Join(t.TempDir(), "other.pem"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := Dial(ctx, []string{addr}, other.Fingerprint); !errors.Is(err, ErrFingerprint) {
		t.Fatalf("ждали ErrFingerprint, получили %v", err)
	}
	if _, err := Dial(ctx, []string{addr}, ""); !errors.Is(err, ErrFingerprint) {
		t.Fatalf("пустой отпечаток: %v", err)
	}
}

func TestDialRace(t *testing.T) {
	_, ident, _, addr := startServer(t)
	dead, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadAddr := dead.Addr().String()
	dead.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, []string{deadAddr, addr}, ident.Fingerprint)
	if err != nil {
		t.Fatalf("из двух адресов один живой, а подключиться не вышло: %v", err)
	}
	c.Close()
	if _, err := Dial(ctx, []string{deadAddr}, ident.Fingerprint); err == nil {
		t.Fatal("подключились к закрытому порту")
	}
}

func TestKick(t *testing.T) {
	srv, ident, host, addr := startServer(t)
	key := host.store.AddClient("phone", "Пиксель")
	c := dial(t, addr, ident.Fingerprint)
	if w, err := c.Hello(Hello{Op: OpAuth, ID: "phone", Key: key}); err != nil || !w.OK {
		t.Fatalf("%+v, %v", w, err)
	}
	if _, err := c.Read(); err != nil {
		t.Fatal(err)
	}
	srv.Kick("phone")
	if _, err := c.Read(); err == nil {
		t.Fatal("после отвязки соединение живо")
	}
}

func TestLinkRoundTrip(t *testing.T) {
	l := PairLink{ID: "pc", Name: "Мой комп & co", Hosts: []string{"192.168.1.5", "10.0.0.2"}, Port: 47391, FP: "fp_-x", Secret: "s3"}
	got, err := ParseLink(l.String())
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != l.ID || got.Name != l.Name || got.Port != l.Port || got.FP != l.FP || got.Secret != l.Secret ||
		strings.Join(got.Hosts, ",") != "192.168.1.5,10.0.0.2" {
		t.Fatalf("ссылка разобрана неверно: %+v", got)
	}
	if a := got.Addrs(); a[0] != "192.168.1.5:47391" {
		t.Fatalf("адреса: %v", a)
	}
	for _, bad := range []string{
		"", "https://music.yandex.ru", "yamp://pair?i=pc&p=1&f=x&s=y",
		"yamp://pair?i=pc&h=host.evil&p=1&f=x&s=y", "yamp://pair?i=pc&h=1.2.3.4&p=70000&f=x&s=y",
		"yamp://other?i=pc&h=1.2.3.4&p=1&f=x&s=y",
	} {
		if _, err := ParseLink(bad); err == nil {
			t.Errorf("приняли %q", bad)
		}
	}
}

func TestBeacon(t *testing.T) {
	b := Beacon{ID: "pc", Name: "Комп", Port: 47391, Login: "user"}
	got, ok := decodeBeacon(encodeBeacon(b))
	if !ok || got.ID != b.ID || got.Name != b.Name || got.Port != b.Port || got.Login != b.Login {
		t.Fatalf("маяк: %+v %v", got, ok)
	}
	for _, bad := range []string{`{"yamp":"other","id":"x","port":1}`, `{"yamp":"yamp-remote","port":1}`, `{"yamp":"yamp-remote","id":"x"}`, `nope`} {
		if _, ok := decodeBeacon([]byte(bad)); ok {
			t.Errorf("приняли маяк %s", bad)
		}
	}

	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	port := probe.LocalAddr().(*net.UDPAddr).Port
	probe.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	found := make(chan Beacon, 4)
	go func() {
		_ = listen(ctx, port, func(b Beacon, from netip.Addr) {
			if from.Is4() {
				found <- b
			}
		})
	}()
	go func() {
		_ = announce(ctx, 50*time.Millisecond, func() Beacon { return b }, func() []*net.UDPAddr {
			return []*net.UDPAddr{{IP: net.IPv4(127, 0, 0, 1), Port: port}}
		})
	}()
	select {
	case got := <-found:
		if got.ID != "pc" || got.Port != 47391 {
			t.Fatalf("принят маяк %+v", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("маяк не дошёл")
	}
}

func TestStore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "remote.json")
	s := LoadStore(path)
	if s.ID == "" {
		t.Fatal("нет своего id")
	}
	key := s.AddClient("phone", "Пиксель")
	s.PutHost(PairedHost{ID: "pc", Name: "Комп", Hosts: []string{"10.0.0.2"}, Port: 1, FP: "f", Key: "k"})
	if err := s.Save(path); err != nil {
		t.Fatal(err)
	}
	loaded := LoadStore(path)
	if loaded.ID != s.ID || !loaded.Authorize("phone", key) || loaded.Authorize("phone", key+"x") {
		t.Fatalf("хранилище: %+v", loaded)
	}
	raw, _ := json.Marshal(loaded)
	if strings.Contains(string(raw), key) {
		t.Fatal("ключ телефона лежит открытым текстом")
	}
	if h, ok := loaded.Host("pc"); !ok || h.Key != "k" {
		t.Fatalf("компьютер не сохранился: %+v", h)
	}
	if !loaded.RemoveClient("phone") || loaded.Authorize("phone", key) {
		t.Fatal("отвязка не сработала")
	}
}
