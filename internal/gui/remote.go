package gui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"yamp/internal/remote"
	"yamp/internal/yam"
)

const (
	remotePortDefault = 47391
	remoteBeaconEvery = 3 * time.Second
	remotePairTTL     = 5 * time.Minute
	remoteSeen        = 10 * time.Second
	remoteRetryMax    = 10 * time.Second
	remoteDialFor     = 8 * time.Second
	remoteNameMax     = 64
	remoteSourceMax   = 512
	remoteTitleMax    = 200
	remoteIndexMax    = 100000

	linkIdle       = "idle"
	linkPairing    = "pairing"
	linkConnecting = "connecting"
	linkOnline     = "online"
	linkOffline    = "offline"
	linkFailed     = "failed"
)

var (
	remotePort     = remotePortDefault
	remoteAnnounce = remote.Announce
	remoteListen   = remote.Listen
	remoteHosts    = remote.LocalHosts

	errUnpaired = errors.New("компьютер не узнал телефон")
)

func remoteStorePath() string { return filepath.Join(filepath.Dir(configPath()), "remote.json") }

func remoteCertPath() string { return filepath.Join(filepath.Dir(configPath()), "remote.pem") }

func remoteName() string {
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return deviceName()
}

type playbackState struct {
	track    string
	playing  bool
	position float64
	at       time.Time
}

type foundHost struct {
	beacon remote.Beacon
	addr   netip.Addr
	seen   time.Time
}

type remoteHub struct {
	path, certPath string

	mu         sync.Mutex
	store      remote.Store
	server     *remote.Server
	ident      *remote.Identity
	stopBeacon context.CancelFunc
	link       string
	expires    time.Time
	player     *playerEvent
	format     map[string]any
	play       playbackState

	scanCancel context.CancelFunc
	scanGen    int
	scanErr    string
	found      map[string]foundHost
	linkID     string
	linkCancel context.CancelFunc
	conn       *remote.Conn
	sends      serial
}

func newRemoteHub() *remoteHub {
	h := &remoteHub{path: remoteStorePath(), certPath: remoteCertPath(), found: map[string]foundHost{}}
	h.store = remote.LoadStore(h.path)
	return h
}

func (g *App) startRemote() {
	h := g.remote
	h.mu.Lock()
	paired := len(h.store.Clients) > 0
	h.mu.Unlock()
	if !paired || runtime.GOOS == "android" {
		return
	}
	if err := g.startRemoteServer(); err != nil {
		g.logf("Пульт: %v", err)
	}
}

type remoteSide struct{ g *App }

func (s remoteSide) Authorize(id, key string) bool {
	h := s.g.remote
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.store.Authorize(id, key)
}

func (s remoteSide) Pair(id, name string) (string, error) {
	name = cleanName(name)
	h := s.g.remote
	h.mu.Lock()
	key := h.store.AddClient(id, name)
	err := h.store.Save(h.path)
	if err != nil {
		h.store.RemoveClient(id)
	} else {
		h.link = ""
	}
	h.mu.Unlock()
	if err != nil {
		return "", err
	}
	s.g.host.post(func() {
		s.g.logf("Пульт: связан телефон «%s»", name)
		s.g.notice("Телефон «"+name+"» связан", "ok")
		s.g.emitRemoteHost()
	})
	return key, nil
}

func (s remoteSide) Snapshot() [][]byte { return s.g.remoteSnapshot() }

func (s remoteSide) Command(id string, line []byte) {
	s.g.host.post(func() { s.g.runRemote(id, line) })
}

func (s remoteSide) Changed() { s.g.host.post(s.g.emitRemoteHost) }

func cleanName(name string) string {
	name = strings.TrimSpace(name)
	if r := []rune(name); len(r) > remoteNameMax {
		name = string(r[:remoteNameMax])
	}
	if name == "" {
		return "Телефон"
	}
	return name
}

func listenRemote(saved int) (net.Listener, error) {
	var ports []int
	if saved > 0 {
		ports = append(ports, saved)
	}
	for _, p := range []int{remotePort, 0} {
		if !slices.Contains(ports, p) {
			ports = append(ports, p)
		}
	}
	var last error
	for _, p := range ports {
		ln, err := net.Listen("tcp", ":"+strconv.Itoa(p))
		if err == nil {
			return ln, nil
		}
		last = err
	}
	return nil, last
}

func (g *App) startRemoteServer() error {
	h := g.remote
	h.mu.Lock()
	if h.server != nil {
		h.mu.Unlock()
		return nil
	}
	ident, err := remote.LoadIdentity(h.certPath)
	if err != nil {
		h.mu.Unlock()
		return fmt.Errorf("не удалось создать сертификат: %w", err)
	}
	ln, err := listenRemote(h.store.Port)
	if err != nil {
		h.mu.Unlock()
		return fmt.Errorf("не удалось открыть порт: %w", err)
	}
	srv := remote.NewServer(ln, ident, h.store.ID, remoteName(), remoteSide{g})
	h.store.Port = srv.Port()
	if err := h.store.Save(h.path); err != nil {
		h.mu.Unlock()
		srv.Close()
		return fmt.Errorf("не удалось сохранить настройки пульта: %w", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.server, h.ident, h.stopBeacon = srv, ident, cancel
	id, port := h.store.ID, srv.Port()
	h.mu.Unlock()

	go srv.Serve()
	go func() {
		if err := remoteAnnounce(ctx, remoteBeaconEvery, func() remote.Beacon { return g.remoteBeacon(id, port) }); err != nil {
			g.logf("Пульт, рассылка в сети: %v", err)
		}
	}()
	g.logf("Пульт: жду телефон на порту %d", port)
	return nil
}

func (g *App) remoteBeacon(id string, port int) remote.Beacon {
	g.mu.Lock()
	login := g.account.Login
	g.mu.Unlock()
	return remote.Beacon{ID: id, Name: remoteName(), Port: port, Login: login}
}

func (g *App) stopRemoteIfIdle() {
	h := g.remote
	h.mu.Lock()
	srv := h.server
	if srv == nil || len(h.store.Clients) > 0 || srv.Pairing() {
		h.mu.Unlock()
		return
	}
	h.server, h.link = nil, ""
	if h.stopBeacon != nil {
		h.stopBeacon()
		h.stopBeacon = nil
	}
	h.mu.Unlock()
	srv.Close()
	g.logf("Пульт выключен: связанных телефонов нет")
}

type remoteDevice struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Online bool   `json:"online"`
	Added  int64  `json:"added"`
}

type remoteHostEvent struct {
	Type      string         `json:"type"`
	Running   bool           `json:"running"`
	Name      string         `json:"name"`
	Port      int            `json:"port,omitempty"`
	Link      string         `json:"link,omitempty"`
	ExpiresIn int            `json:"expiresIn,omitempty"`
	Error     string         `json:"error,omitempty"`
	Devices   []remoteDevice `json:"devices"`
}

func (g *App) emitRemoteHost() { g.emitRemoteHostError("") }

func (g *App) emitRemoteHostError(message string) {
	h := g.remote
	h.mu.Lock()
	srv := h.server
	clients := slices.Clone(h.store.Clients)
	link, expires := h.link, h.expires
	h.mu.Unlock()
	ev := remoteHostEvent{Type: "remoteHost", Name: remoteName(), Running: srv != nil, Error: message, Devices: []remoteDevice{}}
	online := map[string]bool{}
	if srv != nil {
		ev.Port = srv.Port()
		online = srv.Online()
		if left := time.Until(expires); link != "" && srv.Pairing() && left > 0 {
			ev.Link, ev.ExpiresIn = link, int(left.Seconds())
		}
	}
	for _, c := range clients {
		ev.Devices = append(ev.Devices, remoteDevice{ID: c.ID, Name: c.Name, Online: online[c.ID], Added: c.Added})
	}
	g.emit(ev)
}

func (g *App) remotePair() {
	if err := g.startRemoteServer(); err != nil {
		g.emitRemoteHostError(err.Error())
		return
	}
	hosts := remoteHosts(4)
	if len(hosts) == 0 {
		g.stopRemoteIfIdle()
		g.emitRemoteHostError("Компьютер не подключён к локальной сети")
		return
	}
	h := g.remote
	h.mu.Lock()
	srv, ident, id := h.server, h.ident, h.store.ID
	h.mu.Unlock()
	if srv == nil {
		g.emitRemoteHost()
		return
	}
	secret := srv.NewSecret(remotePairTTL)
	link := remote.PairLink{ID: id, Name: remoteName(), Hosts: hosts, Port: srv.Port(), FP: ident.Fingerprint, Secret: secret}
	h.mu.Lock()
	h.link, h.expires = link.String(), time.Now().Add(remotePairTTL)
	h.mu.Unlock()
	g.emitRemoteHost()
}

func (g *App) remotePairCancel() {
	h := g.remote
	h.mu.Lock()
	srv := h.server
	h.link = ""
	h.mu.Unlock()
	if srv != nil {
		srv.ClearSecret()
	}
	g.stopRemoteIfIdle()
	g.emitRemoteHost()
}

func (g *App) remoteUnpair(id string) {
	h := g.remote
	h.mu.Lock()
	removed := h.store.RemoveClient(id)
	var err error
	if removed {
		err = h.store.Save(h.path)
	}
	srv := h.server
	h.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки пульта: "+err.Error(), "error")
	}
	if srv != nil {
		srv.Kick(id)
	}
	g.stopRemoteIfIdle()
	g.emitRemoteHost()
}

func (g *App) remoteKnown(id string) bool {
	h := g.remote
	h.mu.Lock()
	defer h.mu.Unlock()
	return slices.ContainsFunc(h.store.Clients, func(c remote.Client) bool { return c.ID == id })
}

func (g *App) forwardRemote(event any) {
	h := g.remote
	if h == nil {
		return
	}
	var out any
	switch ev := event.(type) {
	case playerEvent:
		start := ev.Start
		ev.Action, ev.URL, ev.NextURL, ev.Start = "", "", "", 0
		h.mu.Lock()
		h.player = &ev
		if ev.Track != nil && ev.Track.ID != h.play.track {
			h.play = playbackState{track: ev.Track.ID, playing: h.play.playing && start == 0, position: start, at: time.Now()}
		}
		h.mu.Unlock()
		out = ev
	case queueEvent:
		out = ev
	case map[string]any:
		switch ev["type"] {
		case "mark":
			out = ev
		case "playerFormat":
			h.mu.Lock()
			h.format = ev
			h.mu.Unlock()
			out = ev
		}
	}
	if out == nil {
		return
	}
	h.mu.Lock()
	srv := h.server
	h.mu.Unlock()
	if srv == nil {
		return
	}
	if line, err := json.Marshal(out); err == nil {
		srv.Broadcast(line)
	}
}

func (g *App) reportPlayback(trackID string, position float64, playing bool) {
	h := g.remote
	h.mu.Lock()
	h.play = playbackState{track: trackID, playing: playing, position: position, at: time.Now()}
	srv := h.server
	h.mu.Unlock()
	g.broadcastPlayback(srv)
}

func (g *App) remoteVolumeChanged() {
	h := g.remote
	h.mu.Lock()
	srv := h.server
	h.mu.Unlock()
	g.broadcastPlayback(srv)
}

func (g *App) broadcastPlayback(srv *remote.Server) {
	if srv == nil {
		return
	}
	if line, err := json.Marshal(g.playbackEvent()); err == nil {
		srv.Broadcast(line)
	}
}

func (g *App) remoteNow() (string, float64, bool) {
	p := g.player
	p.mu.Lock()
	cur, ok := p.queue.Current()
	stored := p.position
	p.mu.Unlock()
	if !ok {
		return "", 0, false
	}
	h := g.remote
	h.mu.Lock()
	play := h.play
	h.mu.Unlock()
	if play.track != cur.ID {
		return cur.ID, stored, false
	}
	pos := play.position
	if play.playing {
		pos += time.Since(play.at).Seconds()
	}
	if d := float64(cur.Duration) / 1000; d > 0 && pos > d {
		pos = d
	}
	return cur.ID, pos, play.playing
}

func (g *App) playbackEvent() map[string]any {
	g.mu.Lock()
	vol := g.cfg.volume()
	g.mu.Unlock()
	track, pos, playing := g.remoteNow()
	return map[string]any{"type": "playback", "track": track, "position": pos, "playing": playing, "volume": vol}
}

func (g *App) remoteSnapshot() [][]byte {
	h := g.remote
	h.mu.Lock()
	player, format := h.player, h.format
	h.mu.Unlock()
	var out [][]byte
	add := func(v any) {
		if b, err := json.Marshal(v); err == nil {
			out = append(out, b)
		}
	}
	if player != nil {
		add(*player)
	}
	add(g.queueSnapshot())
	add(g.playbackEvent())
	if format != nil && player != nil && player.Track != nil && format["track"] == player.Track.ID {
		add(format)
	}
	return out
}

type remoteAction struct {
	core   map[string]any
	ui     map[string]any
	unpair bool
}

type remoteRequest struct {
	Cmd      string   `json:"cmd"`
	Track    string   `json:"track"`
	Pos      *int     `json:"pos"`
	Position *float64 `json:"position"`
	On       bool     `json:"on"`
	Repeat   string   `json:"repeat"`
	Volume   *float64 `json:"volume"`
	Source   string   `json:"source"`
	Index    *int     `json:"index"`
	Title    string   `json:"title"`
}

func remoteTrack(id string) bool {
	if id == "" {
		return true
	}
	if len(id) > 20 {
		return false
	}
	for _, r := range id {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func remoteLink(source string) bool {
	if len(source) > remoteSourceMax || strings.ContainsAny(source, "\r\n\t ") {
		return false
	}
	_, err := yam.ParseLink(source)
	return err == nil
}

func remoteSource(source string) bool {
	switch source {
	case sourceWave, sourceLiked, sourceHistory, yam.ChartLink:
		return true
	}
	return remoteLink(source)
}

func remoteTitle(title string) string {
	title = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < ' ' {
			return -1
		}
		return r
	}, title))
	if r := []rune(title); len(r) > remoteTitleMax {
		title = string(r[:remoteTitleMax])
	}
	return title
}

func translateRemote(line []byte, current string, position float64) (remoteAction, bool) {
	var r remoteRequest
	if json.Unmarshal(line, &r) != nil {
		return remoteAction{}, false
	}
	switch r.Cmd {
	case "playerNext", "playerPrev":
		if current == "" || (r.Track != "" && r.Track != current) {
			return remoteAction{}, false
		}
		return remoteAction{core: map[string]any{"cmd": r.Cmd, "track": current, "position": position}}, true
	case "playerJump":
		if r.Pos == nil || *r.Pos < 0 {
			return remoteAction{}, false
		}
		return remoteAction{core: map[string]any{"cmd": r.Cmd, "pos": *r.Pos, "position": position}}, true
	case "like", "dislike":
		track := r.Track
		if track == "" {
			track = current
		}
		if track == "" {
			return remoteAction{}, false
		}
		return remoteAction{core: map[string]any{"cmd": r.Cmd, "track": track, "on": r.On, "position": position}}, true
	case "playerRepeat":
		return remoteAction{core: map[string]any{"cmd": r.Cmd, "repeat": r.Repeat}}, true
	case "playerShuffle":
		return remoteAction{core: map[string]any{"cmd": r.Cmd, "on": r.On}}, true
	case "play":
		if !remoteSource(r.Source) || !remoteTrack(r.Track) {
			return remoteAction{}, false
		}
		index := 0
		if r.Index != nil {
			index = *r.Index
		}
		if index < -1 || index > remoteIndexMax {
			return remoteAction{}, false
		}
		return remoteAction{core: map[string]any{"cmd": r.Cmd, "source": r.Source, "track": r.Track, "index": index}}, true
	case "wave":
		if (r.Source != "" && !remoteLink(r.Source)) || !remoteTrack(r.Track) || (r.Source == "" && r.Track == "") {
			return remoteAction{}, false
		}
		return remoteAction{core: map[string]any{"cmd": r.Cmd, "source": r.Source, "track": r.Track, "title": remoteTitle(r.Title)}}, true
	case "playerState", "queue":
		return remoteAction{core: map[string]any{"cmd": r.Cmd}}, true
	case "pause", "resume":
		return remoteAction{ui: map[string]any{"type": "remote", "action": r.Cmd}}, true
	case "seek":
		if r.Position == nil || *r.Position < 0 || *r.Position != *r.Position {
			return remoteAction{}, false
		}
		return remoteAction{ui: map[string]any{"type": "remote", "action": "seek", "position": *r.Position}}, true
	case "volume":
		if r.Volume == nil {
			return remoteAction{}, false
		}
		return remoteAction{ui: map[string]any{"type": "remote", "action": "volume", "volume": clampVolume(*r.Volume)}}, true
	case "unpair":
		return remoteAction{unpair: true}, true
	}
	return remoteAction{}, false
}

func (g *App) runRemote(id string, line []byte) {
	if !g.remoteKnown(id) {
		return
	}
	track, pos, _ := g.remoteNow()
	act, ok := translateRemote(line, track, pos)
	if !ok {
		return
	}
	switch {
	case act.unpair:
		g.remoteUnpair(id)
	case act.ui != nil:
		g.emit(act.ui)
	case act.core != nil:
		if b, err := json.Marshal(act.core); err == nil {
			g.onMessage(string(b))
		}
	}
}

type remoteUICommand struct {
	Cmd     string          `json:"cmd"`
	Device  string          `json:"device"`
	On      bool            `json:"on"`
	Link    string          `json:"link"`
	Name    string          `json:"name"`
	Command json.RawMessage `json:"command"`
}

func (g *App) remoteUI(message string) {
	var c remoteUICommand
	if json.Unmarshal([]byte(message), &c) != nil {
		return
	}
	switch c.Cmd {
	case "remoteHost":
		g.emitRemoteHost()
	case "remotePair":
		g.remotePair()
	case "remotePairCancel":
		g.remotePairCancel()
	case "remoteUnpair":
		g.remoteUnpair(c.Device)
	case "remoteScan":
		g.remoteScan(c.On)
	case "remotePairLink":
		g.remotePairLink(c.Link, c.Name)
	case "remoteConnect":
		g.remoteConnect(c.Device, nil)
	case "remoteDisconnect":
		g.remoteDisconnect()
	case "remoteForget":
		g.remoteForget(c.Device)
	case "remoteSend":
		g.remoteSend(c.Command)
	}
}

type remoteHostInfo struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Login  string `json:"login,omitempty"`
	Host   string `json:"host,omitempty"`
	Paired bool   `json:"paired"`
	Online bool   `json:"online"`
}

func (g *App) emitRemoteDevices() {
	h := g.remote
	h.mu.Lock()
	ev := map[string]any{"type": "remoteDevices", "scanning": h.scanCancel != nil, "linked": h.linkID}
	if h.scanErr != "" {
		ev["error"] = h.scanErr
	}
	list := []remoteHostInfo{}
	now := time.Now()
	for _, p := range h.store.Hosts {
		info := remoteHostInfo{ID: p.ID, Name: p.Name, Login: p.Login, Paired: true}
		if len(p.Hosts) > 0 {
			info.Host = p.Hosts[0]
		}
		if f, ok := h.found[p.ID]; ok && now.Sub(f.seen) < remoteSeen {
			info.Online, info.Host = true, f.addr.String()
			if f.beacon.Login != "" {
				info.Login = f.beacon.Login
			}
		}
		list = append(list, info)
	}
	var fresh []remoteHostInfo
	for id, f := range h.found {
		if _, paired := h.store.Host(id); paired || now.Sub(f.seen) >= remoteSeen {
			continue
		}
		fresh = append(fresh, remoteHostInfo{ID: id, Name: f.beacon.Name, Login: f.beacon.Login, Host: f.addr.String(), Online: true})
	}
	h.mu.Unlock()
	slices.SortFunc(fresh, func(a, b remoteHostInfo) int { return strings.Compare(a.Name, b.Name) })
	ev["devices"] = append(list, fresh...)
	g.emit(ev)
}

func (g *App) remoteScan(on bool) {
	h := g.remote
	h.mu.Lock()
	switch {
	case on && h.scanCancel == nil:
		ctx, cancel := context.WithCancel(context.Background())
		h.scanCancel, h.scanErr = cancel, ""
		h.scanGen++
		go g.scanLoop(ctx, h.scanGen)
	case !on && h.scanCancel != nil:
		h.scanCancel()
		h.scanCancel = nil
		h.found = map[string]foundHost{}
	}
	h.mu.Unlock()
	g.emitRemoteDevices()
}

func (g *App) scanLoop(ctx context.Context, gen int) {
	h := g.remote
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
			h.mu.Lock()
			pruned := false
			for id, f := range h.found {
				if time.Since(f.seen) >= remoteSeen {
					delete(h.found, id)
					pruned = true
				}
			}
			h.mu.Unlock()
			if pruned {
				g.emitRemoteDevices()
			}
		}
	}()
	err := remoteListen(ctx, func(b remote.Beacon, addr netip.Addr) {
		h.mu.Lock()
		if h.scanGen != gen {
			h.mu.Unlock()
			return
		}
		prev, had := h.found[b.ID]
		h.found[b.ID] = foundHost{beacon: b, addr: addr, seen: time.Now()}
		changed := !had || prev.addr != addr || prev.beacon != b
		h.mu.Unlock()
		if changed {
			g.emitRemoteDevices()
		}
	})
	if err == nil || ctx.Err() != nil {
		return
	}
	h.mu.Lock()
	if h.scanGen == gen {
		h.scanErr = "Не удалось слушать локальную сеть: " + err.Error()
	}
	h.mu.Unlock()
	g.emitRemoteDevices()
}

func (g *App) emitLink(id, name, status, message string) {
	g.emit(map[string]any{"type": "remoteLink", "id": id, "name": name, "status": status, "message": message})
}

func remoteDialError(err error) string {
	var ne net.Error
	switch {
	case errors.Is(err, remote.ErrFingerprint):
		return "Сертификат компьютера изменился. Если YAMP на компьютере переустановлен, свяжите устройства заново"
	case errors.Is(err, remote.ErrNoAddress):
		return err.Error()
	case errors.As(err, &ne) && ne.Timeout(), errors.Is(err, context.DeadlineExceeded):
		return "Компьютер не отвечает. Проверьте, что YAMP на нём запущен и оба устройства в одной сети"
	}
	return "Не удалось подключиться к компьютеру: " + err.Error()
}

func pairError(code string) string {
	switch code {
	case remote.ErrSecret:
		return "Код устарел или уже использован. Обновите QR-код на компьютере и отсканируйте снова"
	case remote.ErrStore:
		return "Компьютер не смог сохранить связь с телефоном"
	}
	return "Компьютер отказал в связывании"
}

func uniqueHosts(first string, rest []string) []string {
	out := []string{}
	for _, h := range append([]string{first}, rest...) {
		if h != "" && !slices.Contains(out, h) {
			out = append(out, h)
		}
	}
	return out
}

func (g *App) remotePairLink(link, name string) {
	l, err := remote.ParseLink(link)
	if err != nil {
		g.emitLink("", "", linkFailed, err.Error())
		return
	}
	if name = strings.TrimSpace(name); name == "" {
		name = deviceName()
	}
	g.emitLink(l.ID, l.Name, linkPairing, "")
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), remoteDialFor)
		defer cancel()
		conn, err := remote.Dial(ctx, l.Addrs(), l.FP)
		if err != nil {
			g.emitLink(l.ID, l.Name, linkFailed, remoteDialError(err))
			return
		}
		h := g.remote
		h.mu.Lock()
		me := h.store.ID
		h.mu.Unlock()
		w, err := conn.Hello(remote.Hello{Op: remote.OpPair, ID: me, Name: name, Secret: l.Secret})
		if err != nil || !w.OK {
			conn.Close()
			msg := pairError(w.Error)
			if err != nil {
				msg = remoteDialError(err)
			}
			g.emitLink(l.ID, l.Name, linkFailed, msg)
			return
		}
		paired := remote.PairedHost{
			ID: l.ID, Name: l.Name, Hosts: uniqueHosts(conn.Host(), l.Hosts), Port: l.Port, FP: l.FP, Key: w.Key,
			Added: time.Now().Unix(),
		}
		if w.Name != "" {
			paired.Name = w.Name
		}
		h.mu.Lock()
		if f, ok := h.found[l.ID]; ok {
			paired.Login = f.beacon.Login
		}
		h.store.PutHost(paired)
		err = h.store.Save(h.path)
		h.mu.Unlock()
		if err != nil {
			g.notice("Не удалось сохранить связь с компьютером: "+err.Error(), "error")
		}
		g.emitRemoteDevices()
		g.remoteConnect(paired.ID, conn)
	}()
}

func (g *App) remoteConnect(id string, first *remote.Conn) {
	if id == "" {
		return
	}
	h := g.remote
	ctx, cancel := context.WithCancel(context.Background())
	h.mu.Lock()
	if h.linkCancel != nil {
		h.linkCancel()
	}
	h.linkID, h.linkCancel, h.conn = id, cancel, nil
	h.mu.Unlock()
	go g.runLink(ctx, id, first)
}

func (g *App) remoteDisconnect() {
	h := g.remote
	h.mu.Lock()
	id := h.linkID
	if h.linkCancel != nil {
		h.linkCancel()
	}
	h.linkID, h.linkCancel, h.conn = "", nil, nil
	h.mu.Unlock()
	if id != "" {
		g.emitLink(id, "", linkIdle, "")
	}
}

func (g *App) remotePaired(id string) (remote.PairedHost, bool) {
	h := g.remote
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.store.Host(id)
}

func (g *App) forgetHost(id string) {
	h := g.remote
	h.mu.Lock()
	var err error
	if h.store.RemoveHost(id) {
		err = h.store.Save(h.path)
	}
	h.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки пульта: "+err.Error(), "error")
	}
	g.emitRemoteDevices()
}

func (g *App) dialHost(ctx context.Context, p remote.PairedHost) (*remote.Conn, error) {
	h := g.remote
	h.mu.Lock()
	f, found := h.found[p.ID]
	me := h.store.ID
	h.mu.Unlock()
	var addrs []string
	if found {
		addrs = append(addrs, net.JoinHostPort(f.addr.String(), strconv.Itoa(f.beacon.Port)))
	}
	for _, host := range p.Hosts {
		if a := net.JoinHostPort(host, strconv.Itoa(p.Port)); !slices.Contains(addrs, a) {
			addrs = append(addrs, a)
		}
	}
	dctx, cancel := context.WithTimeout(ctx, remoteDialFor)
	defer cancel()
	conn, err := remote.Dial(dctx, addrs, p.FP)
	if err != nil {
		return nil, err
	}
	w, err := conn.Hello(remote.Hello{Op: remote.OpAuth, ID: me, Key: p.Key})
	if err != nil {
		conn.Close()
		return nil, err
	}
	if !w.OK {
		conn.Close()
		if w.Error == remote.ErrUnpaired {
			return nil, errUnpaired
		}
		return nil, errors.New(w.Error)
	}
	hosts := uniqueHosts(conn.Host(), p.Hosts)
	port := p.Port
	if found {
		port = f.beacon.Port
	}
	if !slices.Equal(hosts, p.Hosts) || port != p.Port || (w.Name != "" && w.Name != p.Name) {
		p.Hosts, p.Port = hosts, port
		if w.Name != "" {
			p.Name = w.Name
		}
		h.mu.Lock()
		h.store.PutHost(p)
		_ = h.store.Save(h.path)
		h.mu.Unlock()
	}
	return conn, nil
}

func (g *App) runLink(ctx context.Context, id string, conn *remote.Conn) {
	h := g.remote
	wait := time.Second
	for {
		p, ok := g.remotePaired(id)
		if !ok {
			if conn != nil {
				conn.Close()
			}
			if ctx.Err() == nil {
				g.emitLink(id, "", linkFailed, "Этот компьютер не связан с телефоном")
			}
			return
		}
		if conn == nil {
			g.emitLink(id, p.Name, linkConnecting, "")
			var err error
			conn, err = g.dialHost(ctx, p)
			if ctx.Err() != nil {
				if conn != nil {
					conn.Close()
				}
				return
			}
			switch {
			case errors.Is(err, errUnpaired):
				g.forgetHost(id)
				g.emitLink(id, p.Name, linkFailed, "Компьютер больше не узнаёт этот телефон. Свяжите их заново по QR-коду")
				return
			case errors.Is(err, remote.ErrFingerprint):
				g.emitLink(id, p.Name, linkFailed, remoteDialError(err))
				return
			case err != nil:
				g.emitLink(id, p.Name, linkOffline, remoteDialError(err))
				select {
				case <-ctx.Done():
					return
				case <-time.After(wait):
				}
				wait = min(wait*2, remoteRetryMax)
				continue
			}
		}
		wait = time.Second
		h.mu.Lock()
		if ctx.Err() != nil {
			h.mu.Unlock()
			conn.Close()
			return
		}
		h.conn = conn
		h.mu.Unlock()
		g.emitLink(id, p.Name, linkOnline, "")
		c := conn
		stop := context.AfterFunc(ctx, func() { c.Close() })
		for {
			line, err := c.Read()
			if err != nil {
				break
			}
			if json.Valid(line) {
				g.emit(map[string]any{"type": "remoteEvent", "id": id, "event": json.RawMessage(line)})
			}
		}
		stop()
		c.Close()
		h.mu.Lock()
		if h.conn == c {
			h.conn = nil
		}
		h.mu.Unlock()
		conn = nil
		if ctx.Err() != nil {
			return
		}
		g.emitLink(id, p.Name, linkOffline, "Связь с компьютером прервалась, подключаюсь снова")
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

func (g *App) remoteSend(command json.RawMessage) {
	var head struct {
		Cmd string `json:"cmd"`
	}
	if len(command) == 0 || json.Unmarshal(command, &head) != nil || head.Cmd == "" {
		return
	}
	line, err := json.Marshal(command)
	if err != nil {
		return
	}
	h := g.remote
	h.mu.Lock()
	conn := h.conn
	h.mu.Unlock()
	if conn == nil {
		return
	}
	h.sends.run(func() { _ = conn.Send(line) })
}

func (g *App) remoteForget(id string) {
	h := g.remote
	h.mu.Lock()
	linked := h.linkID == id
	conn := h.conn
	h.mu.Unlock()
	if linked && conn != nil {
		done := make(chan struct{})
		h.sends.run(func() {
			_ = conn.Send([]byte(`{"cmd":"unpair"}`))
			close(done)
		})
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
	}
	if linked {
		g.remoteDisconnect()
	}
	g.forgetHost(id)
}

func (g *App) closeRemote() {
	h := g.remote
	h.mu.Lock()
	srv := h.server
	h.server, h.link = nil, ""
	for _, stop := range []context.CancelFunc{h.stopBeacon, h.scanCancel, h.linkCancel} {
		if stop != nil {
			stop()
		}
	}
	h.stopBeacon, h.scanCancel, h.linkCancel, h.linkID, h.conn = nil, nil, nil, "", nil
	h.mu.Unlock()
	if srv != nil {
		srv.Close()
	}
}
