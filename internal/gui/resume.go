package gui

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"yamp/internal/player"
	"yamp/internal/yam"
)

const (
	resumeBefore = 100
	resumeAfter  = 400
	resumeEvery  = 10 * time.Second
	actRestore   = "restore"
)

type savedPlayer struct {
	Source   *playSource `json:"source,omitempty"`
	Tracks   []yam.Track `json:"tracks"`
	Pos      int         `json:"pos"`
	Position float64     `json:"position"`
	Wave     bool        `json:"wave,omitempty"`
	Seeds    []string    `json:"seeds,omitempty"`
}

func resumePath() string {
	return filepath.Join(filepath.Dir(configPath()), "player.json")
}

func (p *playerState) saved() (savedPlayer, bool) {
	if _, ok := p.queue.Current(); !ok {
		return savedPlayer{}, false
	}
	all := p.queue.Tracks()
	pos := p.queue.Pos()
	from := max(0, pos-resumeBefore)
	to := min(len(all), pos+resumeAfter+1)
	s := savedPlayer{Tracks: all[from:to], Pos: pos - from, Position: p.position}
	if p.source != nil {
		src := *p.source
		s.Source = &src
	}
	if p.wave != nil {
		s.Wave, s.Seeds = true, p.wave.seeds
	}
	return s, true
}

func (g *App) persist() {
	p := g.player
	p.mu.Lock()
	s, ok := p.saved()
	if ok {
		p.savedAt = time.Now()
	}
	p.mu.Unlock()
	if !ok {
		return
	}
	p.saves.run(func() {
		if err := writeResume(s); err != nil {
			g.logf("Плеер, сохранение места: %v", err)
		}
	})
}

func writeResume(s savedPlayer) error {
	path := resumePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	for range 4 {
		if err = os.Rename(tmp, path); err == nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return err
}

func (g *App) flushResume() {
	g.persist()
	done := make(chan struct{})
	g.player.saves.run(func() { close(done) })
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
}

func (g *App) forgetResume() {
	g.player.saves.run(func() { _ = os.Remove(resumePath()) })
}

func (g *App) playerPosition(trackID string, position float64, force, playing bool) {
	p := g.player
	p.mu.Lock()
	cur, ok := p.queue.Current()
	if !ok || cur.ID != trackID {
		p.mu.Unlock()
		return
	}
	p.position = max(position, 0)
	due := force || time.Since(p.savedAt) >= resumeEvery
	p.mu.Unlock()
	g.reportPlayback(trackID, max(position, 0), playing)
	if due {
		g.persist()
	}
}

func (g *App) restorePlayer() {
	p := g.player
	p.mu.Lock()
	done := p.restored
	p.restored = true
	empty := p.queue.Len() == 0
	p.mu.Unlock()
	if done || !empty {
		return
	}
	b, err := os.ReadFile(resumePath())
	if err != nil {
		return
	}
	var s savedPlayer
	if json.Unmarshal(b, &s) != nil || len(s.Tracks) == 0 {
		return
	}
	if sess := g.playerSession(); sess != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		if err := g.ensureLikes(ctx, sess); err != nil {
			g.logf("Лайки: %v", err)
		}
		cancel()
	}
	g.mu.Lock()
	repeat, shuffle := player.ParseRepeat(g.cfg.Repeat), g.cfg.Shuffle
	g.mu.Unlock()

	p.mu.Lock()
	if p.queue.Len() > 0 {
		p.mu.Unlock()
		return
	}
	p.seq++
	p.source, p.wave, p.failures, p.offline = s.Source, nil, 0, false
	if s.Wave {
		repeat, shuffle = waveRepeat(repeat), false
		p.wave = &waveState{seeds: s.Seeds, batches: map[string]string{}}
	}
	p.queue.SetRepeat(repeat)
	p.queue.Restore(s.Tracks, s.Pos, shuffle)
	p.position, p.resumeAt = max(s.Position, 0), max(s.Position, 0)
	p.mu.Unlock()
	g.emitPlayer(actRestore)
	g.emitQueue()
}
