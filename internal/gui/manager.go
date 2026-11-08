package gui

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"yamp/internal/yam"
)

const (
	jobResolving = "resolving"
	jobRunning   = "running"
	jobDone      = "done"
	jobError     = "error"
	jobCancelled = "cancelled"
)

const (
	trackQueued    = "queued"
	trackActive    = "active"
	trackDone      = "done"
	trackSkipped   = "skipped"
	trackError     = "error"
	trackCancelled = "cancelled"
)

type trackState struct {
	Index    int    `json:"i"`
	Title    string `json:"title"`
	Artist   string `json:"artist"`
	Status   string `json:"status"`
	Done     int64  `json:"done"`
	Size     int64  `json:"size"`
	Format   string `json:"format,omitempty"`
	Message  string `json:"message,omitempty"`
	Path     string `json:"path,omitempty"`
	Explicit bool   `json:"explicit,omitempty"`

	dirty bool
}

type job struct {
	ID      int
	Link    string
	Kind    yam.Kind
	Title   string
	Artist  string
	Year    int
	Cover   string
	Dir     string
	Status  string
	Message string

	sel       yam.Selection
	quality   yam.Quality
	tracks    []*trackState
	cancel    context.CancelFunc
	dirty     bool
	tracksNew bool
	Explicit  bool
}

func (j *job) finished() bool {
	return j.Status == jobDone || j.Status == jobError || j.Status == jobCancelled
}

type manager struct {
	app  *App
	gate *gate

	mu     sync.Mutex
	jobs   []*job
	nextID int

	bytes atomic.Int64
}

func newManager(app *App, concurrency int) *manager {
	m := &manager{app: app, gate: newGate(concurrency)}
	go m.ticker()
	return m
}

func (m *manager) add(sess *yam.Session, link string, sel yam.Selection, root string, q yam.Quality) {
	ctx, cancel := context.WithCancel(context.Background())
	m.mu.Lock()
	m.nextID++
	j := &job{ID: m.nextID, Link: link, sel: sel, quality: q, Status: jobResolving, cancel: cancel, dirty: true}
	m.jobs = append(m.jobs, j)
	m.mu.Unlock()
	m.flush()

	go m.run(ctx, j, sess, root, q)
}

func (m *manager) run(ctx context.Context, j *job, sess *yam.Session, root string, q yam.Quality) {
	defer j.cancel()
	fail := func(err error) {
		if errors.Is(err, yam.ErrNoPlus) || errors.Is(err, yam.ErrUnauthorized) {
			m.app.accountLost(err)
		}
		m.finish(j, err)
	}

	if err := sess.Verify(ctx); err != nil {
		fail(err)
		return
	}
	rel, err := resolveJob(ctx, sess, j)
	if err != nil {
		fail(err)
		return
	}
	if len(rel.Tracks) == 0 {
		fail(errors.New("в релизе нет треков"))
		return
	}

	m.mu.Lock()
	j.Kind, j.Title, j.Artist, j.Year, j.Explicit = rel.Kind, rel.Title, rel.Artist, rel.Year, rel.Explicit
	j.Cover = yam.CoverURL(rel.Cover, "200x200")
	j.Dir = filepath.Join(root, rel.Folder())
	j.tracks = make([]*trackState, len(rel.Tracks))
	for i, t := range rel.Tracks {
		j.tracks[i] = &trackState{Index: i, Title: t.Title, Artist: t.Artists, Status: trackQueued, Explicit: t.Explicit}
	}
	j.Status, j.dirty, j.tracksNew = jobRunning, true, true
	m.mu.Unlock()
	m.app.logf("%s: %s - %s, треков: %d", kindName(rel.Kind), rel.Artist, rel.Title, len(rel.Tracks))

	var wg sync.WaitGroup
	for i, t := range rel.Tracks {
		if err := m.gate.acquire(ctx); err != nil {
			break
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer m.gate.release()
			m.downloadTrack(ctx, sess, j, i, rel, t, root, q)
		}()
	}
	wg.Wait()
	m.finish(j, ctx.Err())
}

func resolveJob(ctx context.Context, sess *yam.Session, j *job) (*yam.Release, error) {
	switch j.Link {
	case yam.LikedLink:
		return sess.ResolveLiked(ctx, sess.Account().UID)
	case yam.ChartLink:
		return sess.Chart(ctx)
	}
	link, err := yam.ParseLink(j.Link)
	if err != nil {
		return nil, err
	}
	return sess.ResolveSelected(ctx, link, j.sel)
}

func (m *manager) downloadTrack(ctx context.Context, sess *yam.Session, j *job, i int, rel *yam.Release, t yam.Track, root string, q yam.Quality) {
	ts := j.tracks[i]
	m.update(j, ts, func() { ts.Status = trackActive })

	base := filepath.Join(root, rel.TrackPath(t))
	res, err := sess.DownloadTrack(ctx, t, base, q, func(done, total int64) {
		m.mu.Lock()
		delta := done - ts.Done
		if delta < 0 {
			delta = done
		}
		ts.Done, ts.Size = done, total
		ts.dirty, j.dirty = true, true
		m.mu.Unlock()
		m.bytes.Add(delta)
	})

	prefix := fmt.Sprintf("[%d/%d]", i+1, len(rel.Tracks))
	switch {
	case ctx.Err() != nil:
		m.update(j, ts, func() { ts.Status = trackCancelled })
	case err != nil:
		m.update(j, ts, func() { ts.Status, ts.Message = trackError, err.Error() })
		m.app.logf("%s Ошибка: %s - %s: %v", prefix, t.Artists, t.Title, err)
		if errors.Is(err, yam.ErrUnauthorized) {
			m.app.accountLost(err)
		}
	default:
		m.update(j, ts, func() {
			ts.Status, ts.Format, ts.Path = trackDone, res.Format, res.Path
			ts.Done, ts.Size = res.Size, res.Size
			if res.Skipped {
				ts.Status, ts.Format = trackSkipped, formatFromExt(res.Path)
			}
		})
		if res.Skipped {
			m.app.logf("%s Уже есть: %s", prefix, filepath.Base(res.Path))
		} else {
			m.app.logf("%s Готово: %s (%s, %s)", prefix, filepath.Base(res.Path), res.Format, humanBytes(res.Size))
		}
		if rel.Kind == yam.KindAlbum || rel.Kind == yam.KindArtist {
			sess.SaveCover(ctx, t.Cover, filepath.Dir(base))
		}
	}
}

func (m *manager) update(j *job, ts *trackState, f func()) {
	m.mu.Lock()
	f()
	ts.dirty, j.dirty = true, true
	m.mu.Unlock()
}

func (m *manager) finish(j *job, err error) {
	m.mu.Lock()
	var done, skipped, failed int
	for _, t := range j.tracks {
		switch t.Status {
		case trackDone:
			done++
		case trackSkipped:
			skipped++
		case trackError:
			failed++
		case trackQueued, trackActive:
			t.Status, t.dirty = trackCancelled, true
		}
	}
	switch {
	case errors.Is(err, context.Canceled):
		j.Status, j.Message = jobCancelled, "Остановлено"
	case err != nil:
		j.Status, j.Message = jobError, err.Error()
	case failed > 0 && done+skipped == 0:
		j.Status, j.Message = jobError, "Ни один трек не скачался"
	default:
		j.Status = jobDone
		j.Message = fmt.Sprintf("Скачано %d", done)
		if skipped > 0 {
			j.Message += fmt.Sprintf(", уже было %d", skipped)
		}
		if failed > 0 {
			j.Message += fmt.Sprintf(", ошибок %d", failed)
		}
	}
	j.dirty = true
	title, status, msg := j.Title, j.Status, j.Message
	m.mu.Unlock()
	m.flush()

	if title == "" {
		title = j.Link
	}
	m.app.logf("%s: %s", title, msg)
	switch status {
	case jobDone:
		m.app.notice(title+": "+msg, "ok")
	case jobError:
		m.app.notice(title+": "+msg, "error")
	}
}

func (m *manager) find(id int) *job {
	for _, j := range m.jobs {
		if j.ID == id {
			return j
		}
	}
	return nil
}

func (m *manager) cancel(id int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, j := range m.jobs {
		if (id == 0 || j.ID == id) && !j.finished() {
			j.cancel()
		}
	}
}

func (m *manager) retry(sess *yam.Session, id int, root string, q yam.Quality) {
	m.mu.Lock()
	j := m.find(id)
	link := ""
	var sel yam.Selection
	if j != nil && j.finished() {
		link, sel = j.Link, j.sel
		if j.quality != "" {
			q = j.quality
		}
	}
	m.mu.Unlock()
	if link != "" {
		m.remove(id)
		m.add(sess, link, sel, root, q)
	}
}

func (m *manager) remove(id int) {
	m.mu.Lock()
	var removed []int
	kept := m.jobs[:0]
	for _, j := range m.jobs {
		if (id == 0 || j.ID == id) && j.finished() {
			removed = append(removed, j.ID)
			continue
		}
		kept = append(kept, j)
	}
	m.jobs = kept
	m.mu.Unlock()
	for _, id := range removed {
		m.app.emit(map[string]any{"type": "jobRemoved", "id": id})
	}
}

func (m *manager) busy() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, j := range m.jobs {
		if !j.finished() {
			return true
		}
	}
	return false
}

type jobEvent struct {
	Type     string        `json:"type"`
	ID       int           `json:"id"`
	Link     string        `json:"link"`
	Kind     string        `json:"kind"`
	Title    string        `json:"title"`
	Artist   string        `json:"artist"`
	Year     int           `json:"year"`
	Cover    string        `json:"cover"`
	Dir      string        `json:"dir"`
	Status   string        `json:"status"`
	Message  string        `json:"message"`
	Total    int           `json:"total"`
	Full     bool          `json:"full"`
	Tracks   []*trackState `json:"tracks,omitempty"`
	Explicit bool          `json:"explicit,omitempty"`
}

func (j *job) snapshot(all bool) jobEvent {
	e := jobEvent{
		Type: "job", ID: j.ID, Link: j.Link, Kind: string(j.Kind),
		Title: j.Title, Artist: j.Artist, Year: j.Year, Cover: j.Cover, Dir: j.Dir,
		Status: j.Status, Message: j.Message, Total: len(j.tracks), Explicit: j.Explicit,
		Full: all || j.tracksNew,
	}
	for _, t := range j.tracks {
		if e.Full || t.dirty {
			cp := *t
			e.Tracks = append(e.Tracks, &cp)
		}
		t.dirty = false
	}
	j.dirty, j.tracksNew = false, false
	return e
}

func (m *manager) flush() {
	m.mu.Lock()
	var events []jobEvent
	for _, j := range m.jobs {
		if j.dirty {
			events = append(events, j.snapshot(false))
		}
	}
	m.mu.Unlock()
	for _, e := range events {
		m.app.emit(e)
	}
}

func (m *manager) emitAll() {
	m.mu.Lock()
	events := make([]jobEvent, 0, len(m.jobs))
	for _, j := range m.jobs {
		events = append(events, j.snapshot(true))
	}
	m.mu.Unlock()
	for _, e := range events {
		m.app.emit(e)
	}
}

func (m *manager) ticker() {
	const period = 200 * time.Millisecond
	t := time.NewTicker(period)
	defer t.Stop()
	var last int64
	var speed float64
	wasActive := false
	for range t.C {
		m.flush()

		total := m.bytes.Load()
		inst := float64(total-last) / period.Seconds()
		last = total
		speed = speed*0.7 + inst*0.3

		m.mu.Lock()
		active, queued := 0, 0
		for _, j := range m.jobs {
			for _, ts := range j.tracks {
				switch ts.Status {
				case trackActive:
					active++
				case trackQueued:
					queued++
				}
			}
		}
		m.mu.Unlock()

		if active == 0 && queued == 0 {
			speed = 0
			if !wasActive {
				continue
			}
		}
		wasActive = active > 0 || queued > 0
		m.app.emit(map[string]any{"type": "stats", "speed": speed, "active": active, "queued": queued})
	}
}

func kindName(k yam.Kind) string {
	switch k {
	case yam.KindAlbum:
		return "Альбом"
	case yam.KindPlaylist:
		return "Плейлист"
	case yam.KindArtist:
		return "Исполнитель"
	}
	return "Трек"
}

func formatFromExt(path string) string {
	switch filepath.Ext(path) {
	case ".flac":
		return "FLAC"
	case ".mp3":
		return "MP3"
	case ".m4a":
		return "AAC"
	}
	return ""
}

func humanBytes(n int64) string {
	const k = 1024.0
	f := float64(n)
	switch {
	case f < k:
		return fmt.Sprintf("%d Б", n)
	case f < k*k:
		return fmt.Sprintf("%.1f КБ", f/k)
	case f < k*k*k:
		return fmt.Sprintf("%.1f МБ", f/(k*k))
	}
	return fmt.Sprintf("%.2f ГБ", f/(k*k*k))
}
