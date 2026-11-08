package gui

import (
	"context"
	"time"

	"yamp/internal/yam"
)

const lyricsKeep = 32

type lyricsEvent struct {
	Type    string          `json:"type"`
	Track   string          `json:"track"`
	Synced  bool            `json:"synced"`
	Lines   []yam.LyricLine `json:"lines"`
	Writers []string        `json:"writers,omitempty"`
	Error   string          `json:"error,omitempty"`
}

func (p *playerState) lyricsKind(trackID string) yam.LyricsKind {
	for _, t := range p.queue.Tracks() {
		if t.ID == trackID {
			return t.Lyrics
		}
	}
	for _, l := range p.lists {
		for _, t := range l.Tracks {
			if t.ID == trackID {
				return t.Lyrics
			}
		}
	}
	return yam.LyricsUnknown
}

func (g *App) lyrics(trackID string) {
	sess := g.needSession()
	if sess == nil || trackID == "" {
		return
	}
	p := g.player
	p.mu.Lock()
	if ev, ok := p.lyrics[trackID]; ok {
		p.mu.Unlock()
		g.emit(ev)
		return
	}
	kind := p.lyricsKind(trackID)
	p.mu.Unlock()

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		l, err := sess.Lyrics(ctx, trackID, kind)
		ev := lyricsEvent{Type: "lyrics", Track: trackID, Synced: l.Synced, Lines: l.Lines, Writers: l.Writers}
		if ev.Lines == nil {
			ev.Lines = []yam.LyricLine{}
		}
		if err != nil {
			g.logf("Текст песни %s: %v", trackID, err)
			ev.Error = searchError(err)
			g.emit(ev)
			return
		}
		p.mu.Lock()
		if p.bound == sess {
			if len(p.lyrics) >= lyricsKeep {
				p.lyrics = map[string]lyricsEvent{}
			}
			p.lyrics[trackID] = ev
		}
		p.mu.Unlock()
		g.emit(ev)
	}()
}
