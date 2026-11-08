package gui

import (
	"context"
	"errors"
	"math/rand/v2"
	"slices"
	"strings"
	"sync"
	"time"

	"yamp/internal/player"
	"yamp/internal/yam"
)

const (
	sourceWave    = "wave"
	sourceLiked   = "liked"
	sourceHistory = "history"

	playFrom      = "desktop_win-yamp-player-default"
	restartAfter  = 3.0
	maxFailures   = 3
	waveLow       = 2
	waveQueueKeep = 100
	listTTL       = 2 * time.Minute
	listKeep      = 8
	retryFirst    = 2 * time.Second
	retryMax      = 15 * time.Second
	probeTimeout  = 15 * time.Second
)

const (
	actPlay   = "play"
	actResume = "resume"
	actStop   = "stop"
	actEnd    = "end"
	actRetry  = "retry"
)

type playSource struct {
	Kind    string       `json:"kind"`
	ID      string       `json:"id"`
	Title   string       `json:"title"`
	Cover   string       `json:"cover,omitempty"`
	Artist  string       `json:"artist,omitempty"`
	Artists []playArtist `json:"artists,omitempty"`
	Year    int          `json:"year,omitempty"`
}

type playArtist struct {
	Name   string `json:"name"`
	Source string `json:"source"`
}

func playArtists(refs []yam.ArtistRef) []playArtist {
	if len(refs) == 0 {
		return nil
	}
	out := make([]playArtist, 0, len(refs))
	for _, a := range refs {
		out = append(out, playArtist{Name: a.Name, Source: "https://music.yandex.ru/artist/" + a.ID})
	}
	return out
}

type sourceAlbum struct {
	Source   string `json:"source"`
	Title    string `json:"title"`
	Year     int    `json:"year,omitempty"`
	Cover    string `json:"cover,omitempty"`
	Count    int    `json:"count"`
	Type     string `json:"type"`
	Explicit bool   `json:"explicit,omitempty"`
}

func sourceAlbums(list []yam.AlbumInfo) []sourceAlbum {
	out := make([]sourceAlbum, 0, len(list))
	for _, a := range list {
		out = append(out, sourceAlbum{
			Source: "https://music.yandex.ru/album/" + a.ID, Title: a.Title, Year: a.Year,
			Cover: yam.CoverURL(a.Cover, "400x400"), Count: a.TrackCount, Type: a.Type, Explicit: a.Explicit,
		})
	}
	return out
}

type playTrack struct {
	ID          string       `json:"id"`
	AlbumID     string       `json:"albumId,omitempty"`
	Title       string       `json:"title"`
	Artist      string       `json:"artist"`
	Artists     []playArtist `json:"artists,omitempty"`
	Album       string       `json:"album,omitempty"`
	AlbumSource string       `json:"albumSource,omitempty"`
	Cover       string       `json:"cover,omitempty"`
	Duration    int          `json:"durationMs"`
	Explicit    bool         `json:"explicit,omitempty"`
	Liked       bool         `json:"liked,omitempty"`
	Disliked    bool         `json:"disliked,omitempty"`
	Unavailable bool         `json:"unavailable,omitempty"`
	Link        string       `json:"link,omitempty"`
	Lyrics      string       `json:"lyrics,omitempty"`
}

type playerEvent struct {
	Type    string      `json:"type"`
	Action  string      `json:"action,omitempty"`
	Track   *playTrack  `json:"track"`
	Art     string      `json:"art,omitempty"`
	URL     string      `json:"url,omitempty"`
	Next    *playTrack  `json:"next,omitempty"`
	NextURL string      `json:"nextUrl,omitempty"`
	Pos     int         `json:"pos"`
	Count   int         `json:"count"`
	Repeat  string      `json:"repeat"`
	Shuffle bool        `json:"shuffle"`
	Wave    bool        `json:"wave"`
	Loading bool        `json:"loading,omitempty"`
	Offline bool        `json:"offline,omitempty"`
	Start   float64     `json:"start,omitempty"`
	Quality string      `json:"quality"`
	Auto    bool        `json:"autoQuality,omitempty"`
	Volume  float64     `json:"volume"`
	Source  *playSource `json:"source,omitempty"`
}

type queueEvent struct {
	Type   string      `json:"type"`
	Pos    int         `json:"pos"`
	Tracks []playTrack `json:"tracks"`
	Source *playSource `json:"source,omitempty"`
}

type trackList struct {
	Source playSource
	Tracks []yam.Track
	Albums []yam.AlbumInfo
	Days   []historyDay
	at     time.Time
}

type historyDay struct {
	Date  string `json:"date"`
	Count int    `json:"count"`
}

type waveState struct {
	session string
	seeds   []string
	batches map[string]string
	loading bool
	pending bool
}

type playerState struct {
	mu sync.Mutex

	queue  player.Queue
	source *playSource
	seq    int
	wave   *waveState

	bound    *yam.Session
	likesFor *yam.Session
	liked    []string
	likes    map[string]bool
	dislikes map[string]bool

	lists    map[string]*trackList
	lyrics   map[string]lyricsEvent
	failures int
	offline  bool
	resumeAt float64
	position float64
	savedAt  time.Time
	restored bool

	reports serial
	saves   serial
}

type serial struct {
	mu      sync.Mutex
	queue   []func()
	running bool
}

func (s *serial) run(f func()) {
	s.mu.Lock()
	s.queue = append(s.queue, f)
	if s.running {
		s.mu.Unlock()
		return
	}
	s.running = true
	s.mu.Unlock()
	go func() {
		for {
			s.mu.Lock()
			if len(s.queue) == 0 {
				s.running = false
				s.mu.Unlock()
				return
			}
			next := s.queue[0]
			s.queue = s.queue[1:]
			s.mu.Unlock()
			next()
		}
	}()
}

func newPlayerState(cfg config) *playerState {
	p := &playerState{likes: map[string]bool{}, dislikes: map[string]bool{}, lists: map[string]*trackList{}, lyrics: map[string]lyricsEvent{}}
	p.queue.SetRepeat(player.ParseRepeat(cfg.Repeat))
	p.queue.SetShuffle(cfg.Shuffle)
	return p
}

func (p *playerState) shape(t yam.Track, cover string) playTrack {
	pt := playTrack{
		ID: t.ID, AlbumID: t.AlbumID, Title: t.Title, Artist: t.Artists, Artists: playArtists(t.ArtistRefs), Album: t.Album,
		Cover: yam.CoverURL(t.Cover, cover), Duration: t.Duration, Explicit: t.Explicit,
		Liked: p.likes[t.ID], Disliked: p.dislikes[t.ID], Unavailable: !t.Available, Lyrics: string(t.Lyrics),
	}
	switch {
	case t.AlbumID != "":
		pt.AlbumSource = "https://music.yandex.ru/album/" + t.AlbumID
		pt.Link = pt.AlbumSource + "/track/" + t.ID
	case t.ID != "":
		pt.Link = "https://music.yandex.ru/track/" + t.ID
	}
	return pt
}

func (p *playerState) shapeAll(list []yam.Track) []playTrack {
	out := make([]playTrack, 0, len(list))
	for _, t := range list {
		out = append(out, p.shape(t, "200x200"))
	}
	return out
}

func (g *App) playerSession() *yam.Session {
	g.mu.Lock()
	sess := g.session
	g.mu.Unlock()
	g.bindStream(sess)
	return sess
}

func (g *App) bindStream(sess *yam.Session) {
	p := g.player
	p.mu.Lock()
	changed := p.bound != sess
	p.bound = sess
	p.mu.Unlock()
	if !changed {
		return
	}
	var c *yam.Client
	if sess != nil {
		c = sess.Client
	}
	g.stream.streamer.SetClient(c)
}

func (g *App) needSession() *yam.Session {
	sess := g.playerSession()
	if sess == nil {
		g.notice(yam.ErrNoPlus.Error(), "error")
	}
	return sess
}

func (g *App) playerReset() {
	p := g.player
	p.mu.Lock()
	p.seq++
	p.queue.Clear()
	p.source, p.wave, p.offline = nil, nil, false
	p.likesFor, p.liked = nil, nil
	p.likes, p.dislikes = map[string]bool{}, map[string]bool{}
	p.lists = map[string]*trackList{}
	p.lyrics = map[string]lyricsEvent{}
	p.mu.Unlock()
	g.bindStream(nil)
	g.emitPlayer(actStop)
}

func (g *App) ensureLikes(ctx context.Context, sess *yam.Session) error {
	p := g.player
	p.mu.Lock()
	loaded := p.likesFor == sess
	p.mu.Unlock()
	if loaded {
		return nil
	}
	uid := sess.Account().UID
	liked, err := sess.LikedTrackIDs(ctx, uid)
	if err != nil {
		return err
	}
	disliked, err := sess.DislikedTrackIDs(ctx, uid)
	if err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.bound != sess {
		return nil
	}
	p.likesFor, p.liked = sess, liked
	p.likes, p.dislikes = map[string]bool{}, map[string]bool{}
	for _, id := range liked {
		p.likes[id] = true
	}
	for _, id := range disliked {
		p.dislikes[id] = true
	}
	return nil
}

type libraryPlaylist struct {
	Source string `json:"source"`
	Title  string `json:"title"`
	Owner  string `json:"owner,omitempty"`
	Count  int    `json:"count"`
	Cover  string `json:"cover,omitempty"`
}

func libraryPlaylists(hits []yam.Hit) []libraryPlaylist {
	out := make([]libraryPlaylist, 0, len(hits))
	for _, h := range hits {
		out = append(out, libraryPlaylist{
			Source: h.Link, Title: h.Title, Owner: h.Artist, Count: h.Count,
			Cover: yam.CoverURL(h.Cover, "200x200"),
		})
	}
	return out
}

func (g *App) library() {
	sess := g.needSession()
	if sess == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		uid := sess.Account().UID
		ev := map[string]any{"type": "library"}
		var wg sync.WaitGroup
		var own, liked []yam.Hit
		var ownErr, likedErr, likesErr error
		wg.Add(3)
		go func() { defer wg.Done(); own, ownErr = sess.UserPlaylists(ctx, uid) }()
		go func() { defer wg.Done(); liked, likedErr = sess.LikedPlaylists(ctx, uid) }()
		go func() { defer wg.Done(); likesErr = g.ensureLikes(ctx, sess) }()
		wg.Wait()
		if err := errors.Join(ownErr, likedErr, likesErr); err != nil {
			g.logf("Библиотека: %v", err)
		}
		if ownErr != nil && likedErr != nil {
			ev["error"] = searchError(ownErr)
			g.emit(ev)
			return
		}
		g.player.mu.Lock()
		ev["likedCount"] = len(g.player.liked)
		g.player.mu.Unlock()
		ev["playlists"] = libraryPlaylists(own)
		ev["likedPlaylists"] = libraryPlaylists(liked)
		g.emit(ev)
	}()
}

func (g *App) loadSource(ctx context.Context, sess *yam.Session, source string) (*trackList, error) {
	p := g.player
	p.mu.Lock()
	if l := p.lists[source]; l != nil && time.Since(l.at) < listTTL {
		p.mu.Unlock()
		return l, nil
	}
	p.mu.Unlock()

	if err := g.ensureLikes(ctx, sess); err != nil {
		g.logf("Лайки: %v", err)
	}
	var list *trackList
	if source == sourceLiked {
		p.mu.Lock()
		ids := slices.Clone(p.liked)
		p.mu.Unlock()
		tracks, err := sess.Tracks(ctx, ids)
		if err != nil {
			return nil, err
		}
		list = &trackList{Source: playSource{Kind: sourceLiked, ID: sourceLiked, Title: "Мне нравится"}, Tracks: tracks}
	} else if source == sourceHistory {
		days, err := sess.HistoryDays(ctx)
		if err != nil {
			return nil, err
		}
		list = &trackList{Source: playSource{Kind: sourceHistory, ID: sourceHistory, Title: "История"}}
		for _, d := range days {
			list.Tracks = append(list.Tracks, d.Tracks...)
			list.Days = append(list.Days, historyDay{Date: d.Date, Count: len(d.Tracks)})
		}
	} else if source == yam.ChartLink {
		rel, err := sess.Chart(ctx)
		if err != nil {
			return nil, err
		}
		list = &trackList{Source: playSource{Kind: yam.ChartLink, ID: yam.ChartLink, Title: rel.Title}, Tracks: rel.Tracks}
	} else {
		l, err := yam.ParseLink(source)
		if err != nil {
			return nil, err
		}
		var rel *yam.Release
		if l.Kind == yam.KindArtist {
			rel, err = sess.ArtistPage(ctx, l.ArtistID)
		} else {
			rel, err = sess.Resolve(ctx, l, true)
		}
		if err != nil {
			return nil, err
		}
		list = &trackList{
			Source: playSource{
				Kind: string(rel.Kind), ID: source, Title: rel.Title, Cover: yam.CoverURL(rel.Cover, "400x400"),
				Artist: rel.Artist, Artists: playArtists(rel.Artists), Year: rel.Year,
			},
			Tracks: rel.Tracks,
			Albums: rel.Albums,
		}
	}
	list.at = time.Now()
	p.mu.Lock()
	if len(p.lists) >= listKeep {
		p.lists = map[string]*trackList{}
	}
	p.lists[source] = list
	p.mu.Unlock()
	return list, nil
}

func (g *App) openSource(source string) {
	sess := g.needSession()
	if sess == nil || source == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		list, err := g.loadSource(ctx, sess, source)
		if err != nil {
			g.emit(map[string]any{"type": "tracks", "source": source, "error": searchError(err)})
			return
		}
		g.player.mu.Lock()
		tracks := g.player.shapeAll(list.Tracks)
		g.player.mu.Unlock()
		ev := map[string]any{"type": "tracks", "source": source, "info": list.Source, "tracks": tracks}
		if list.Days != nil {
			ev["days"] = list.Days
		}
		if len(list.Albums) > 0 && list.Source.Kind == string(yam.KindArtist) && !strings.HasSuffix(source, "/tracks") {
			ev["albums"] = sourceAlbums(list.Albums)
		}
		g.emit(ev)
	}()
}

func playable(list []yam.Track) []yam.Track {
	out := make([]yam.Track, 0, len(list))
	for _, t := range list {
		if t.Available {
			out = append(out, t)
		}
	}
	return out
}

func (g *App) play(source, trackID string, index int, seeds []string) {
	sess := g.needSession()
	if sess == nil {
		return
	}
	if source == "" {
		source = sourceWave
	}
	if source == sourceWave {
		g.startWave(sess, waveStart{seeds: seeds})
		return
	}
	g.mu.Lock()
	shuffle, repeat := g.cfg.Shuffle, player.ParseRepeat(g.cfg.Repeat)
	g.mu.Unlock()
	p := g.player
	p.mu.Lock()
	p.seq++
	seq := p.seq
	p.mu.Unlock()

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		list, err := g.loadSource(ctx, sess, source)
		if err != nil {
			g.notice("Не удалось открыть: "+searchError(err), "error")
			return
		}
		tracks := playable(list.Tracks)
		if len(tracks) == 0 {
			g.notice("Здесь нет треков, которые можно послушать", "error")
			return
		}
		start := max(0, min(index, len(tracks)-1))
		if index >= 0 && index < len(list.Tracks) && list.Tracks[index].ID == trackID && list.Tracks[index].Available {
			start = len(playable(list.Tracks[:index]))
		} else if i := slices.IndexFunc(tracks, func(t yam.Track) bool { return t.ID == trackID }); i >= 0 {
			start = i
		} else if trackID == "" && index < 0 && shuffle {
			start = rand.IntN(len(tracks))
		}
		p.mu.Lock()
		if seq != p.seq {
			p.mu.Unlock()
			return
		}
		src := list.Source
		p.source, p.wave, p.failures, p.offline = &src, nil, 0, false
		p.queue.SetRepeat(repeat)
		p.queue.SetShuffle(shuffle)
		p.queue.Set(tracks, start)
		p.mu.Unlock()
		g.emitPlayer(actPlay)
		g.emitQueue()
	}()
}

func waveRepeat(r player.Repeat) player.Repeat {
	if r == player.RepeatAll {
		return player.RepeatOff
	}
	return r
}

type waveStart struct {
	seeds    []string
	fallback []string
	title    string
	played   []yam.Track
	keep     *yam.Track
}

func waveSeeds(source, trackID string) (seeds, fallback []string) {
	if trackID != "" {
		fallback = []string{"track:" + trackID}
	}
	if l, err := yam.ParseLink(source); err == nil {
		switch l.Kind {
		case yam.KindAlbum:
			seeds = []string{"album:" + l.AlbumID}
		case yam.KindArtist:
			seeds = []string{"artist:" + l.ArtistID}
		case yam.KindPlaylist:
			if l.Owner != "" && l.PlaylistKind != "" {
				seeds = []string{"playlist:" + l.Owner + "_" + l.PlaylistKind}
			}
		case yam.KindTrack:
			seeds = []string{"track:" + l.TrackID}
		}
	}
	if len(seeds) == 0 {
		seeds, fallback = fallback, nil
	}
	return seeds, fallback
}

func (g *App) waveFrom(source, trackID, title string) {
	sess := g.needSession()
	if sess == nil {
		return
	}
	seeds, fallback := waveSeeds(source, trackID)
	if len(seeds) == 0 {
		g.notice("По этому нельзя запустить волну", "error")
		return
	}
	if title != "" {
		title = "Моя волна: " + title
	}
	start := waveStart{seeds: seeds, fallback: fallback, title: title}
	if source == "" && trackID != "" {
		p := g.player
		p.mu.Lock()
		if cur, ok := p.queue.Current(); ok && cur.ID == trackID {
			start.keep = &cur
			start.played = []yam.Track{cur}
		}
		p.mu.Unlock()
	}
	g.startWave(sess, start)
}

func (g *App) startWave(sess *yam.Session, start waveStart) {
	seeds := start.seeds
	title := start.title
	if title == "" {
		title = "Моя волна"
	}
	played := start.played
	if len(played) > waveQueueKeep {
		played = played[len(played)-waveQueueKeep:]
	}
	g.mu.Lock()
	repeat := waveRepeat(player.ParseRepeat(g.cfg.Repeat))
	g.mu.Unlock()
	p := g.player
	p.mu.Lock()
	p.seq++
	seq := p.seq
	p.queue.SetRepeat(repeat)
	p.queue.SetShuffle(false)
	if start.keep != nil {
		p.queue.Set([]yam.Track{*start.keep}, 0)
	} else {
		p.queue.Clear()
	}
	p.source = &playSource{Kind: sourceWave, ID: sourceWave, Title: title}
	p.wave = &waveState{seeds: seeds, batches: map[string]string{}, loading: true, pending: start.keep == nil}
	p.failures, p.offline = 0, false
	p.mu.Unlock()
	g.emitPlayer("")

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := g.ensureLikes(ctx, sess); err != nil {
			g.logf("Лайки: %v", err)
		}
		batch, err := sess.WaveStart(ctx, seeds, played)
		if err == nil && len(batch.Tracks) == 0 {
			err = errors.New("Яндекс не прислал треков")
		}
		if err != nil && len(start.fallback) > 0 {
			g.logf("Моя волна по %v: %v", seeds, err)
			seeds = start.fallback
			batch, err = sess.WaveStart(ctx, seeds, played)
			if err == nil && len(batch.Tracks) == 0 {
				err = errors.New("Яндекс не прислал треков")
			}
		}
		p.mu.Lock()
		if seq != p.seq || p.wave == nil {
			p.mu.Unlock()
			return
		}
		w := p.wave
		w.loading = false
		if err != nil {
			p.wave, p.source = nil, nil
			p.mu.Unlock()
			g.notice("Не удалось запустить Мою волну: "+searchError(err), "error")
			if start.keep != nil {
				g.emitPlayer("")
				g.emitQueue()
				return
			}
			g.emitPlayer(actStop)
			return
		}
		w.session, w.pending, w.seeds = batch.Session, false, seeds
		g.addBatch(batch)
		seen := map[string]bool{}
		for _, t := range played {
			seen[t.ID] = true
		}
		var fresh []yam.Track
		for _, t := range batch.Tracks {
			if !seen[t.ID] && !p.dislikes[t.ID] {
				fresh = append(fresh, t)
			}
		}
		if len(fresh) == 0 && start.keep == nil {
			fresh = batch.Tracks
		}
		action := actPlay
		if start.keep != nil {
			p.queue.Append(fresh)
			action = ""
		} else {
			p.queue.Set(fresh, 0)
		}
		p.mu.Unlock()
		p.reports.run(func() { g.waveFeedback(sess, batch.Session, batch.Batch, yam.WaveStarted, "", 0) })
		g.emitPlayer(action)
		g.emitQueue()
	}()
}

func (g *App) addBatch(b yam.WaveBatch) {
	p := g.player
	for _, t := range b.Tracks {
		p.wave.batches[t.ID] = b.Batch
	}
	for id := range b.Liked {
		if !p.likes[id] {
			p.likes[id] = true
			p.liked = append([]string{id}, p.liked...)
		}
	}
}

func (g *App) waveRefill(sess *yam.Session) {
	p := g.player
	p.mu.Lock()
	w := p.wave
	if w == nil || w.loading || p.queue.Remaining() >= waveLow {
		p.mu.Unlock()
		return
	}
	w.loading = true
	seq := p.seq
	known := p.queue.Tracks()
	if len(known) > waveQueueKeep {
		known = known[len(known)-waveQueueKeep:]
	}
	session, seeds := w.session, w.seeds
	p.mu.Unlock()

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		var batch yam.WaveBatch
		var err error
		if session != "" {
			batch, err = sess.WaveNext(ctx, session, known)
		}
		if session == "" || errors.Is(err, yam.ErrWaveEnded) {
			batch, err = sess.WaveStart(ctx, seeds, known)
			if err == nil {
				b := batch
				p.reports.run(func() { g.waveFeedback(sess, b.Session, b.Batch, yam.WaveStarted, "", 0) })
			}
		}
		p.mu.Lock()
		if seq != p.seq || p.wave != w {
			p.mu.Unlock()
			return
		}
		w.loading = false
		if err != nil {
			pending := w.pending
			w.pending = false
			p.mu.Unlock()
			g.logf("Моя волна: %v", err)
			if pending {
				g.notice("Моя волна не отвечает: "+searchError(err), "error")
				g.emitPlayer(actEnd)
			}
			return
		}
		w.session = batch.Session
		seen := map[string]bool{}
		for _, t := range known {
			seen[t.ID] = true
		}
		var fresh []yam.Track
		for _, t := range batch.Tracks {
			if !seen[t.ID] && !p.dislikes[t.ID] {
				fresh = append(fresh, t)
			}
		}
		g.addBatch(batch)
		p.queue.Append(fresh)
		action := ""
		if w.pending && len(fresh) > 0 {
			w.pending = false
			p.queue.Next(false)
			action = actPlay
		}
		p.mu.Unlock()
		g.emitPlayer(action)
		g.emitQueue()
	}()
}

func (g *App) waveFeedback(sess *yam.Session, session, batch string, ev yam.WaveEvent, trackID string, played float64) {
	if session == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := sess.WaveFeedback(ctx, session, batch, ev, trackID, played); err != nil {
		g.logf("Моя волна, отзыв %s: %v", ev, err)
	}
}

func (g *App) reportPlay(sess *yam.Session, t yam.Track, wave *waveState, played, position float64, ended bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	from := playFrom
	if wave != nil {
		from = yam.WaveFrom
		ev := yam.WaveSkip
		if ended {
			ev = yam.WaveTrackFinished
		}
		g.waveFeedback(sess, wave.session, wave.batches[t.ID], ev, t.ID, played)
	}
	if err := sess.ReportPlay(ctx, sess.Account().UID, yam.Play{Track: t, From: from, Played: played, Position: position}); err != nil {
		g.logf("История прослушиваний: %v", err)
	}
}

func (g *App) forward(trackID string, played float64, ended bool) {
	g.moveOn(trackID, played, ended, true, func(q *player.Queue) bool { return q.Next(ended) })
}

func (g *App) move(trackID string, played float64, ended bool, step func(q *player.Queue) bool) {
	g.moveOn(trackID, played, ended, false, step)
}

func (g *App) moveOn(trackID string, played float64, ended, onward bool, step func(q *player.Queue) bool) {
	sess := g.playerSession()
	p := g.player
	p.mu.Lock()
	cur, ok := p.queue.Current()
	if trackID != "" && (!ok || cur.ID != trackID) {
		p.mu.Unlock()
		return
	}
	w := p.wave
	var snapshot *waveState
	if w != nil {
		snapshot = &waveState{session: w.session, batches: map[string]string{cur.ID: w.batches[cur.ID]}}
	}
	p.offline = false
	moved := step(&p.queue)
	waiting := !moved && w != nil
	if waiting {
		w.pending = true
	}
	var history []yam.Track
	if !moved && w == nil && onward && ok {
		history = p.queue.Played()
	}
	p.mu.Unlock()

	if ok && sess != nil && played > 0 {
		p.reports.run(func() { g.reportPlay(sess, cur, snapshot, played, played, ended) })
	}
	if w != nil && sess != nil {
		g.waveRefill(sess)
	}
	switch {
	case moved:
		g.emitPlayer(actPlay)
	case waiting:
		g.emitPlayer("")
	case history != nil && sess != nil:
		g.startWave(sess, waveStart{seeds: []string{"track:" + cur.ID}, played: history})
	default:
		g.emitPlayer(actEnd)
	}
}

func (g *App) playerPrev(trackID string, position float64) {
	if position > restartAfter {
		p := g.player
		p.mu.Lock()
		cur, ok := p.queue.Current()
		p.mu.Unlock()
		if ok && (trackID == "" || cur.ID == trackID) {
			g.emitPlayer(actPlay)
		}
		return
	}
	g.move(trackID, position, false, (*player.Queue).Prev)
}

func (g *App) playerStarted(trackID string) {
	sess := g.playerSession()
	p := g.player
	p.mu.Lock()
	cur, ok := p.queue.Current()
	if !ok || cur.ID != trackID {
		p.mu.Unlock()
		return
	}
	p.failures = 0
	var session, batch string
	if p.wave != nil {
		session, batch = p.wave.session, p.wave.batches[cur.ID]
	}
	p.mu.Unlock()
	if session != "" && sess != nil {
		p.reports.run(func() { g.waveFeedback(sess, session, batch, yam.WaveTrackStarted, cur.ID, 0) })
	}
}

func (g *App) playerFailed(trackID, message string, position float64) {
	p := g.player
	p.mu.Lock()
	cur, ok := p.queue.Current()
	if !ok || cur.ID != trackID || p.offline {
		p.mu.Unlock()
		return
	}
	seq, pos := p.seq, p.queue.Pos()
	p.failures++
	failures := p.failures
	p.mu.Unlock()
	g.logf("Плеер: %s - %s: %s", cur.Artists, cur.Title, message)

	go func() {
		offline := g.offline(trackID)
		p.mu.Lock()
		now, ok := p.queue.Current()
		if seq != p.seq || pos != p.queue.Pos() || !ok || now.ID != trackID || p.offline {
			p.mu.Unlock()
			return
		}
		if offline {
			p.offline, p.failures = true, 0
			p.mu.Unlock()
			g.logf("Плеер: нет связи, жду сеть")
			g.emitPlayer("")
			g.waitOnline(seq, pos, trackID, position)
			return
		}
		p.mu.Unlock()
		switch {
		case failures < maxFailures && position > 0:
			g.retryAt(position)
		case position > 0:
			g.forward(trackID, position, false)
		case failures >= maxFailures:
			p.mu.Lock()
			p.failures = 0
			p.mu.Unlock()
			g.notice("Не удаётся воспроизвести треки. Проверьте подключение или смените качество", "error")
			g.emitPlayer(actEnd)
		default:
			g.notice("Не удалось воспроизвести «"+cur.Title+"», включаю следующий", "error")
			g.forward(trackID, 0, false)
		}
	}()
}

func (g *App) offline(trackID string) bool {
	g.mu.Lock()
	q := g.cfg.playback(g.metered)
	g.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), probeTimeout)
	defer cancel()
	return yam.Offline(g.stream.streamer.Check(ctx, trackID, q))
}

func (g *App) waitOnline(seq, pos int, trackID string, position float64) {
	p := g.player
	waiting := func() bool {
		p.mu.Lock()
		defer p.mu.Unlock()
		cur, ok := p.queue.Current()
		return p.offline && seq == p.seq && pos == p.queue.Pos() && ok && cur.ID == trackID
	}
	delay := retryFirst
	for {
		time.Sleep(delay)
		delay = min(delay*2, retryMax)
		if !waiting() {
			return
		}
		if !g.offline(trackID) {
			break
		}
	}
	if !waiting() {
		return
	}
	g.logf("Плеер: сеть вернулась")
	p.mu.Lock()
	p.offline = false
	p.mu.Unlock()
	g.retryAt(position)
}

func (g *App) retryAt(position float64) {
	p := g.player
	p.mu.Lock()
	p.resumeAt = max(position, 0)
	p.mu.Unlock()
	g.emitPlayer(actRetry)
}

func (g *App) setPlayerQuality(q string) {
	g.changePlayback(func(c *config) {
		auto := q == "auto"
		c.AutoQuality = &auto
		if !auto {
			c.PlayQuality = string(playQuality(q))
		}
	})
}

func (g *App) setPlayback(c uiCommand) {
	g.changePlayback(func(cfg *config) {
		if c.Auto != nil {
			auto := *c.Auto
			cfg.AutoQuality = &auto
		}
		if c.Quality != "" {
			cfg.PlayQuality = string(playQuality(c.Quality))
		}
		if c.Wifi != "" {
			cfg.WifiQuality = string(playQuality(c.Wifi))
		}
		if c.Mobile != "" {
			cfg.MobileQuality = string(playQuality(c.Mobile))
		}
	})
}

func (g *App) changePlayback(change func(c *config)) {
	g.mu.Lock()
	before := g.cfg.playback(g.metered)
	change(&g.cfg)
	after := g.cfg.playback(g.metered)
	err := g.cfg.save()
	g.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки: "+err.Error(), "error")
	}
	g.emitState(false)
	if after != before {
		g.emitPlayer(actResume)
		return
	}
	g.emitPlayer("")
}

func (g *App) setMetered(on bool) {
	g.mu.Lock()
	changed := g.metered != on
	g.metered = on
	g.mu.Unlock()
	if !changed {
		return
	}
	g.logf("Сеть: %s", map[bool]string{true: "мобильная", false: "безлимитная"}[on])
	g.emitState(false)
	g.emitPlayer("")
}

func (g *App) setVolume(v float64) {
	v = clampVolume(v)
	g.mu.Lock()
	g.cfg.Volume = &v
	err := g.cfg.save()
	g.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки: "+err.Error(), "error")
	}
	g.remoteVolumeChanged()
}

func (g *App) setRepeat(r string) {
	rep := player.ParseRepeat(r)
	g.mu.Lock()
	g.cfg.Repeat = string(rep)
	err := g.cfg.save()
	g.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки: "+err.Error(), "error")
	}
	p := g.player
	p.mu.Lock()
	if p.wave != nil {
		rep = waveRepeat(rep)
	}
	p.queue.SetRepeat(rep)
	p.mu.Unlock()
	g.emitPlayer("")
}

func (g *App) setShuffle(on bool) {
	g.mu.Lock()
	g.cfg.Shuffle = on
	err := g.cfg.save()
	g.mu.Unlock()
	if err != nil {
		g.notice("Не удалось сохранить настройки: "+err.Error(), "error")
	}
	p := g.player
	p.mu.Lock()
	wave := p.wave != nil
	if !wave {
		p.queue.SetShuffle(on)
	}
	p.mu.Unlock()
	g.emitPlayer("")
	if !wave {
		g.emitQueue()
	}
}

func (g *App) mark(trackID string, on, dislike bool, position float64) {
	sess := g.needSession()
	if sess == nil || trackID == "" {
		return
	}
	p := g.player
	p.mu.Lock()
	prevLike, prevDislike := p.likes[trackID], p.dislikes[trackID]
	prevLiked := slices.Clone(p.liked)
	if dislike {
		p.dislikes[trackID] = on
		if on {
			g.setLiked(trackID, false)
		}
	} else {
		g.setLiked(trackID, on)
		if on {
			p.dislikes[trackID] = false
		}
	}
	delete(p.lists, sourceLiked)
	cur, ok := p.queue.Current()
	skip := dislike && on && ok && cur.ID == trackID
	p.mu.Unlock()
	g.emitMark(trackID)
	if skip {
		g.forward(trackID, position, false)
	} else {
		g.emitPlayer("")
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		uid := sess.Account().UID
		var err error
		if dislike {
			err = sess.DislikeTracks(ctx, uid, []string{trackID}, on)
		} else {
			err = sess.LikeTracks(ctx, uid, []string{trackID}, on)
		}
		if err == nil {
			return
		}
		p.mu.Lock()
		p.likes[trackID], p.dislikes[trackID], p.liked = prevLike, prevDislike, prevLiked
		p.mu.Unlock()
		g.notice("Не удалось сохранить отметку: "+searchError(err), "error")
		g.emitMark(trackID)
		g.emitPlayer("")
	}()
}

func (g *App) setLiked(trackID string, on bool) {
	p := g.player
	if p.likes[trackID] == on {
		return
	}
	p.likes[trackID] = on
	p.liked = slices.DeleteFunc(p.liked, func(id string) bool { return id == trackID })
	if on {
		p.liked = append([]string{trackID}, p.liked...)
	}
}

func (g *App) emitMark(trackID string) {
	p := g.player
	p.mu.Lock()
	ev := map[string]any{
		"type": "mark", "track": trackID,
		"liked": p.likes[trackID], "disliked": p.dislikes[trackID], "likedCount": len(p.liked),
	}
	p.mu.Unlock()
	g.emit(ev)
}

func (g *App) emitPlayer(action string) {
	g.mu.Lock()
	q, vol, auto := g.cfg.playback(g.metered), g.cfg.volume(), g.cfg.autoQuality()
	g.mu.Unlock()

	p := g.player
	p.mu.Lock()
	ev := playerEvent{
		Type: "player", Action: action, Pos: p.queue.Pos(), Count: p.queue.Len(),
		Repeat: string(p.queue.Repeat()), Shuffle: p.queue.Shuffle(), Quality: string(q), Auto: auto, Volume: vol,
		Wave: p.wave != nil, Loading: p.offline || (p.wave != nil && p.wave.pending), Offline: p.offline,
	}
	switch action {
	case actPlay:
		p.position = 0
	case actRetry:
		p.position = p.resumeAt
		ev.Start = p.resumeAt
	case actRestore:
		ev.Start = p.resumeAt
	}
	if p.source != nil {
		src := *p.source
		ev.Source = &src
	}
	cur, ok := p.queue.Current()
	next, hasNext := p.queue.Peek()
	if ok {
		t := p.shape(cur, "200x200")
		ev.Track = &t
		ev.Art = yam.CoverURL(cur.Cover, "800x800")
	}
	if hasNext {
		t := p.shape(next, "200x200")
		ev.Next = &t
	}
	p.mu.Unlock()

	if ev.Track == nil {
		if action == actPlay || action == actResume || action == actRetry || action == actRestore {
			ev.Action = actStop
		}
		g.emit(ev)
		return
	}
	g.persist()
	var err error
	if ev.URL, err = g.stream.url(cur.ID, q); err != nil {
		g.notice("Не удалось запустить плеер: "+err.Error(), "error")
		return
	}
	if hasNext {
		ev.NextURL, _ = g.stream.url(next.ID, q)
	}
	g.emit(ev)
	if action == actPlay || action == actResume || action == actRetry {
		go g.prepare(cur.ID, q, true)
		if hasNext {
			go g.prepare(next.ID, q, false)
		}
	}
}

func (g *App) prepare(trackID string, q yam.Quality, announce bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	f, err := g.stream.streamer.Prepare(ctx, trackID, q)
	if !announce {
		return
	}
	if err != nil {
		g.logf("Плеер, поток %s: %v", trackID, err)
		return
	}
	g.emit(map[string]any{
		"type": "playerFormat", "track": trackID, "quality": string(q),
		"format": f.String(), "codec": f.Codec, "bitrate": f.Bitrate, "lossless": f.Lossless,
	})
}

func (g *App) emitQueue() {
	g.emit(g.queueSnapshot())
}

func (g *App) queueSnapshot() queueEvent {
	p := g.player
	p.mu.Lock()
	defer p.mu.Unlock()
	ev := queueEvent{Type: "queue", Pos: p.queue.Pos(), Tracks: p.shapeAll(p.queue.Tracks())}
	if p.source != nil {
		src := *p.source
		ev.Source = &src
	}
	return ev
}
