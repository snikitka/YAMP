package gui

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"yamp/internal/discord"
	"yamp/internal/yam"
)

const Version = "0.2.1"

const (
	accNone     = "none"
	accChecking = "checking"
	accOK       = "ok"
	accNoPlus   = "noplus"
	accError    = "error"
)

type App struct {
	host *Core
	logs logBuffer
	jobs *manager
	upd  selfUpdate

	player *playerState
	stream *streamServer
	remote *remoteHub

	mu      sync.Mutex
	cfg     config
	metered bool
	token   string
	session *yam.Session
	account accountEvent
	checkID int

	searchCancel context.CancelFunc
	deviceCancel context.CancelFunc
	grant        *yam.Grant

	discord  *discord.Client
	presence *discord.Activity
}

type accountEvent struct {
	Type    string `json:"type"`
	Status  string `json:"status"`
	Login   string `json:"login,omitempty"`
	Name    string `json:"name,omitempty"`
	HasPlus bool   `json:"hasPlus"`
	Message string `json:"message,omitempty"`
}

func newApp() *App {
	g := &App{cfg: loadConfig(), stream: newStreamServer(), remote: newRemoteHub()}
	g.player = newPlayerState(g.cfg)
	g.token = g.cfg.token()
	g.account = accountEvent{Type: "account", Status: accNone}
	g.discord = discord.New(discordID(), func(s string) { g.logf("%s", s) })
	return g
}

func (g *App) start() {
	g.jobs = newManager(g, g.cfg.Concurrency)
	g.startUpdates()
	g.startRemote()
	if g.token != "" {
		g.checkAccount(g.token, false)
		go g.refreshGrant()
	}
}

func (g *App) setAccount(a accountEvent) {
	a.Type = "account"
	g.mu.Lock()
	g.account = a
	g.mu.Unlock()
	g.emit(a)
}

func (g *App) checkAccount(token string, save bool) {
	g.mu.Lock()
	g.checkID++
	id := g.checkID
	g.mu.Unlock()
	g.mu.Lock()
	prev := g.account
	g.mu.Unlock()
	checking := accountEvent{Status: accChecking}
	if !save {
		checking.Login, checking.Name = prev.Login, prev.Name
	}
	g.setAccount(checking)

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		sess, acc, err := yam.Open(ctx, token)

		g.mu.Lock()
		if id != g.checkID {
			g.mu.Unlock()
			return
		}
		ev := accountEvent{Login: acc.Login, Name: acc.Name, HasPlus: acc.HasPlus}
		keep := true
		switch {
		case err == nil:
			ev.Status = accOK
		case errors.Is(err, yam.ErrNoPlus):
			ev.Status, ev.Message = accNoPlus, err.Error()
		case errors.Is(err, yam.ErrUnauthorized):
			ev.Status, ev.Message = accError, err.Error()
			keep = false
		default:
			ev.Status, ev.Message = accError, "Нет связи с Яндекс Музыкой: "+err.Error()
		}
		g.session = sess
		if keep {
			g.token = token
		} else if !save {

			g.token = ""
		}
		var saveErr error
		var revoke string
		if (save && keep) || (!save && !keep) {
			grant := g.grant
			if grant != nil && grant.AccessToken != g.token {
				grant = nil
			}
			if old := g.cfg.token(); save && g.cfg.Refresh != "" && old != "" && old != token {
				revoke = old
			}
			if saveErr = g.cfg.setToken(g.token); saveErr == nil {
				saveErr = g.cfg.setGrant(grant)
			}
			if saveErr == nil {
				saveErr = g.cfg.save()
			}
		}
		g.grant = nil
		g.mu.Unlock()

		if revoke != "" {
			g.revoke(revoke)
		}
		g.setAccount(ev)
		if err == nil {
			g.restorePlayer()
		}
		if saveErr != nil {
			g.notice("Не удалось сохранить токен: "+saveErr.Error(), "error")
		}
	}()
}

func (g *App) accountLost(err error) {
	g.mu.Lock()
	if g.session == nil {
		g.mu.Unlock()
		return
	}
	acc := g.session.Account()
	g.session = nil
	g.mu.Unlock()

	g.jobs.cancel(0)
	g.playerReset()
	ev := accountEvent{Status: accError, Message: err.Error(), Login: acc.Login, Name: acc.Name}
	if errors.Is(err, yam.ErrNoPlus) {
		ev.Status, ev.HasPlus = accNoPlus, false
	}
	g.setAccount(ev)
}

func (g *App) logout() {
	g.jobs.cancel(0)
	g.mu.Lock()
	g.checkID++
	g.token, g.session, g.grant = "", nil, nil
	if g.searchCancel != nil {
		g.searchCancel()
		g.searchCancel = nil
	}
	if g.deviceCancel != nil {
		g.deviceCancel()
		g.deviceCancel = nil
	}
	var revoke string
	if g.cfg.Refresh != "" {
		revoke = g.cfg.token()
	}
	_ = g.cfg.setToken("")
	_ = g.cfg.setGrant(nil)
	err := g.cfg.save()
	g.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки: "+err.Error(), "error")
	}
	if revoke != "" {
		g.revoke(revoke)
	}
	g.playerReset()
	g.forgetResume()
	g.setAccount(accountEvent{Status: accNone})
}

func (g *App) recheck() {
	g.mu.Lock()
	token, sess, acc, id := g.token, g.session, g.account, g.checkID
	g.mu.Unlock()
	if token == "" {
		g.setAccount(accountEvent{Status: accNone})
		return
	}
	if sess == nil {
		g.checkAccount(token, false)
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		fresh, err := sess.Refresh(ctx)
		g.mu.Lock()
		stale := id != g.checkID || sess != g.session
		g.mu.Unlock()
		if stale {
			return
		}
		switch {
		case err == nil:
			g.setAccount(accountEvent{Status: accOK, Login: fresh.Login, Name: fresh.Name, HasPlus: true})
			g.notice("Подписка Плюс активна", "ok")
		case errors.Is(err, yam.ErrNoPlus), errors.Is(err, yam.ErrUnauthorized):
			g.accountLost(err)
		default:
			g.setAccount(acc)
			g.notice("Не удалось проверить подписку: "+err.Error(), "error")
		}
	}()
}

func (g *App) startDownload(link, dir string, sel yam.Selection, quality string) {
	g.mu.Lock()
	sess := g.session
	if dir == "" {
		dir = g.cfg.Dir
	}
	q := g.cfg.quality()
	g.mu.Unlock()
	switch yam.Quality(quality) {
	case yam.Lossless, yam.MP3:
		q = yam.Quality(quality)
	}

	if sess == nil {
		g.notice(yam.ErrNoPlus.Error(), "error")
		return
	}
	if g.updating() {
		g.notice("Идёт обновление YAMP", "error")
		return
	}
	if link != yam.LikedLink && link != yam.ChartLink {
		if _, err := yam.ParseLink(link); err != nil {
			g.notice(err.Error(), "error")
			return
		}
	}
	if dir == "" {
		g.notice("Укажите папку для сохранения", "error")
		return
	}
	g.jobs.add(sess, link, sel, dir, q)
}

func (g *App) retry(id int) {
	g.mu.Lock()
	sess, dir, q := g.session, g.cfg.Dir, g.cfg.quality()
	g.mu.Unlock()
	if sess == nil {
		g.notice(yam.ErrNoPlus.Error(), "error")
		return
	}
	g.jobs.retry(sess, id, dir, q)
}

type previewEvent struct {
	Type     string      `json:"type"`
	Link     string      `json:"link"`
	Status   string      `json:"status"`
	Kind     string      `json:"kind,omitempty"`
	Title    string      `json:"title,omitempty"`
	Artist   string      `json:"artist,omitempty"`
	Year     int         `json:"year,omitempty"`
	Cover    string      `json:"cover,omitempty"`
	Count    int         `json:"count,omitempty"`
	Folder   string      `json:"folder,omitempty"`
	Albums   []albumItem `json:"albums,omitempty"`
	Explicit bool        `json:"explicit,omitempty"`
	Message  string      `json:"message,omitempty"`
}

func (g *App) preview(link string) {
	g.mu.Lock()
	token := g.token
	g.mu.Unlock()

	if link == "" {
		return
	}
	l, err := yam.ParseLink(link)
	if err != nil {
		g.emit(previewEvent{Type: "preview", Link: link, Status: "error", Message: err.Error()})
		return
	}
	if token == "" {
		return
	}

	g.emit(previewEvent{Type: "preview", Link: link, Status: "loading", Kind: string(l.Kind)})

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		rel, err := yam.New(token).Resolve(ctx, l, false)
		if err != nil {
			g.emit(previewEvent{Type: "preview", Link: link, Status: "error", Kind: string(l.Kind), Message: err.Error()})
			return
		}
		albums := albumItems(rel.Albums)
		if rel.Kind == yam.KindPlaylist && rel.TrackCount > 0 {
			albums = []albumItem{{
				ID: playlistPrefix + link, Title: rel.Title, Count: rel.TrackCount, Type: "album",
				Cover: yam.CoverURL(rel.Cover, "100x100"),
			}}
		}
		g.emit(previewEvent{
			Type: "preview", Link: link, Status: "ok", Kind: string(rel.Kind),
			Title: rel.Title, Artist: rel.Artist, Year: rel.Year,
			Cover: yam.CoverURL(rel.Cover, "400x400"), Count: rel.TrackCount,
			Folder: rel.Folder(), Albums: albums, Explicit: rel.Explicit,
		})
	}()
}

const playlistPrefix = "playlist:"

type albumItem struct {
	Explicit bool   `json:"explicit,omitempty"`
	ID       string `json:"id"`
	Title    string `json:"title"`
	Year     int    `json:"year"`
	Cover    string `json:"cover"`
	Count    int    `json:"count"`
	Type     string `json:"type"`
}

func albumItems(list []yam.AlbumInfo) []albumItem {
	out := make([]albumItem, 0, len(list))
	for _, a := range list {
		out = append(out, albumItem{
			ID: a.ID, Title: a.Title, Year: a.Year, Count: a.TrackCount, Type: a.Type, Explicit: a.Explicit,
			Cover: yam.CoverURL(a.Cover, "100x100"),
		})
	}
	return out
}

type albumTrack struct {
	Explicit bool   `json:"explicit,omitempty"`
	ID       string `json:"id"`
	Title    string `json:"title"`
	Artist   string `json:"artist"`
	Number   int    `json:"number"`
	Disc     int    `json:"disc"`
}

func (g *App) listTracks(ctx context.Context, c *yam.Client, id string) ([]yam.Track, error) {
	link, ok := strings.CutPrefix(id, playlistPrefix)
	if !ok {
		return c.AlbumTracks(ctx, id)
	}
	l, err := yam.ParseLink(link)
	if err != nil {
		return nil, err
	}
	rel, err := c.Resolve(ctx, l, true)
	if err != nil {
		return nil, err
	}
	for i := range rel.Tracks {
		rel.Tracks[i].Number = i + 1
	}
	return rel.Tracks, nil
}

func (g *App) albumTracks(id string) {
	g.mu.Lock()
	token := g.token
	g.mu.Unlock()
	if token == "" || id == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		tracks, err := g.listTracks(ctx, yam.New(token), id)
		if err != nil {
			g.emit(map[string]any{"type": "albumTracks", "id": id, "error": err.Error()})
			return
		}
		items := make([]albumTrack, 0, len(tracks))
		for _, t := range tracks {
			items = append(items, albumTrack{ID: t.ID, Title: t.Title, Artist: t.Artists, Number: t.Number, Disc: t.Disc, Explicit: t.Explicit})
		}
		g.emit(map[string]any{"type": "albumTracks", "id": id, "tracks": items})
	}()
}
