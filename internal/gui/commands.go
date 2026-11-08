package gui

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strings"

	"yamp/internal/player"
	"yamp/internal/yam"
)

type uiCommand struct {
	Cmd         string   `json:"cmd"`
	Token       string   `json:"token"`
	Link        string   `json:"link"`
	Dir         string   `json:"dir"`
	Theme       string   `json:"theme"`
	Quality     string   `json:"quality"`
	Concurrency int      `json:"concurrency"`
	ID          int      `json:"id"`
	Album       string   `json:"album"`
	Query       string   `json:"query"`
	Kind        string   `json:"kind"`
	Page        int      `json:"page"`
	Seq         int      `json:"seq"`
	Source      string   `json:"source"`
	Track       string   `json:"track"`
	Index       int      `json:"index"`
	Pos         int      `json:"pos"`
	Position    float64  `json:"position"`
	On          bool     `json:"on"`
	Repeat      string   `json:"repeat"`
	Volume      float64  `json:"volume"`
	Seeds       []string `json:"seeds"`
	Message     string   `json:"message"`
	Auto        *bool    `json:"auto"`
	Wifi        string   `json:"wifi"`
	Mobile      string   `json:"mobile"`
	Metered     bool     `json:"metered"`
	Discord     *bool    `json:"discord"`
	Crossfade   *bool    `json:"crossfade"`
	Fade        int      `json:"fade"`
	Title       string   `json:"title"`
	Artist      string   `json:"artist"`
	Cover       string   `json:"cover"`
	Duration    float64  `json:"duration"`
	Playing     bool     `json:"playing"`
	Select      []struct {
		Album  string   `json:"album"`
		Tracks []string `json:"tracks"`
	} `json:"select"`
}

func (g *App) onMessage(message string) {
	var c uiCommand
	if err := json.Unmarshal([]byte(message), &c); err != nil {
		return
	}
	switch c.Cmd {
	case "ready":
		g.emitState(true)
		g.mu.Lock()
		acc := g.account
		g.mu.Unlock()
		g.emit(acc)
		g.jobs.emitAll()
		g.emitPlayer("")
		g.onReady()
	case "checkUpdate":
		g.checkUpdate(false)
	case "applyUpdate":
		g.applyUpdate()
	case "login":
		token := extractToken(c.Token)
		if token == "" {
			g.notice("Вставьте токен Яндекс Музыки", "error")
			return
		}
		g.checkAccount(token, true)
	case "deviceLogin":
		g.deviceLogin()
	case "deviceCancel":
		g.deviceCancelLogin()
	case "recheck":
		g.recheck()
	case "logout":
		g.logout()
	case "prefs":
		g.setPrefs(c)
	case "preview":
		g.preview(strings.TrimSpace(c.Link))
	case "download":
		var sel yam.Selection
		if len(c.Select) > 0 {
			sel = yam.Selection{}
			for _, s := range c.Select {
				sel[s.Album] = s.Tracks
			}
		}
		g.startDownload(strings.TrimSpace(c.Link), strings.TrimSpace(c.Dir), sel, c.Quality)
	case "album":
		g.albumTracks(c.Album)
	case "search":
		g.search(c.Seq, strings.TrimSpace(c.Query), c.Kind, c.Page)
	case "library":
		g.library()
	case "home":
		g.home()
	case "open":
		g.openSource(strings.TrimSpace(c.Source))
	case "play":
		g.play(strings.TrimSpace(c.Source), c.Track, c.Index, c.Seeds)
	case "wave":
		g.waveFrom(strings.TrimSpace(c.Source), c.Track, c.Title)
	case "playerNext":
		g.forward(c.Track, c.Position, false)
	case "playerEnded":
		g.forward(c.Track, c.Position, true)
	case "playerPrev":
		g.playerPrev(c.Track, c.Position)
	case "playerJump":
		g.move("", c.Position, false, func(q *player.Queue) bool { return q.Jump(c.Pos) })
	case "playerStarted":
		g.playerStarted(c.Track)
	case "playerError":
		g.playerFailed(c.Track, c.Message, c.Position)
	case "playerQuality":
		g.setPlayerQuality(c.Quality)
	case "playQuality":
		g.setPlayback(c)
	case "network":
		g.setMetered(c.Metered)
	case "playerVolume":
		g.setVolume(c.Volume)
	case "playerRepeat":
		g.setRepeat(c.Repeat)
	case "playerShuffle":
		g.setShuffle(c.On)
	case "playerPosition":
		g.playerPosition(c.Track, c.Position, c.On, c.Playing)
	case "playerState":
		g.emitPlayer("")
	case "queue":
		g.emitQueue()
	case "presence":
		g.setPresence(c)
	case "like":
		g.mark(c.Track, c.On, false, c.Position)
	case "lyrics":
		g.lyrics(strings.TrimSpace(c.Track))
	case "dislike":
		g.mark(c.Track, c.On, true, c.Position)
	case "cancel":
		g.jobs.cancel(c.ID)
	case "retry":
		g.retry(c.ID)
	case "remove":
		g.jobs.remove(c.ID)
	case "exit":
		g.closeRemote()
		g.flushResume()
		g.jobs.cancel(0)
		g.host.post(g.host.exit)
	default:
		if strings.HasPrefix(c.Cmd, "remote") {
			g.remoteUI(message)
		}
	}
}

var accessTokenRe = regexp.MustCompile(`access_token=([^&#\s]+)`)

func extractToken(s string) string {
	s = strings.TrimSpace(s)
	if m := accessTokenRe.FindStringSubmatch(s); m != nil {
		if t, err := url.QueryUnescape(m[1]); err == nil {
			return t
		}
		return m[1]
	}
	return s
}

func (g *App) setPrefs(c uiCommand) {
	g.mu.Lock()
	if c.Dir != "" {
		g.cfg.Dir = c.Dir
	}
	if c.Theme != "" {
		g.cfg.Theme = c.Theme
	}
	if c.Quality != "" {
		g.cfg.Quality = c.Quality
		g.cfg.Quality = string(g.cfg.quality())
	}
	if c.Concurrency != 0 {
		g.cfg.Concurrency = clampConcurrency(c.Concurrency)
		g.jobs.gate.setLimit(g.cfg.Concurrency)
	}
	if c.Discord != nil {
		on := *c.Discord
		g.cfg.Discord = &on
	}
	if c.Crossfade != nil {
		on := *c.Crossfade
		g.cfg.Crossfade = &on
	}
	if c.Fade != 0 {
		g.cfg.Fade = clampFade(c.Fade)
	}
	err := g.cfg.save()
	g.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки: "+err.Error(), "error")
	}
	if c.Discord != nil {
		g.applyPresence()
	}
	g.emitState(false)
}
