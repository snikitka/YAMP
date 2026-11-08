package gui

import (
	"context"
	"errors"
	"sync"
	"time"

	"yamp/internal/yam"
)

const (
	homeRow   = 12
	homeChart = 10
)

func hitEvents(list []yam.Hit) []searchHit {
	out := make([]searchHit, 0, len(list))
	for _, h := range list {
		out = append(out, hitEvent(h))
	}
	return out
}

func (g *App) home() {
	sess := g.needSession()
	if sess == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		var personal, history, releases, playlists []yam.Hit
		var chart *trackList
		errs := make([]error, 5)
		var wg sync.WaitGroup
		wg.Add(5)
		go func() { defer wg.Done(); personal, errs[0] = sess.PersonalPlaylists(ctx) }()
		go func() { defer wg.Done(); history, errs[1] = sess.History(ctx, homeRow) }()
		go func() { defer wg.Done(); releases, errs[2] = sess.NewReleases(ctx, homeRow) }()
		go func() { defer wg.Done(); playlists, errs[3] = sess.NewPlaylists(ctx, homeRow) }()
		go func() { defer wg.Done(); chart, errs[4] = g.loadSource(ctx, sess, yam.ChartLink) }()
		wg.Wait()

		failed := 0
		for _, err := range errs {
			if err != nil {
				failed++
			}
		}
		if failed > 0 {
			g.logf("Главная: %v", errors.Join(errs...))
		}
		ev := map[string]any{"type": "home"}
		if failed == len(errs) {
			ev["error"] = searchError(errs[0])
			g.emit(ev)
			return
		}
		ev["personal"] = hitEvents(personal)
		ev["history"] = hitEvents(history)
		ev["releases"] = hitEvents(releases)
		ev["playlists"] = hitEvents(playlists)
		if chart != nil {
			top := chart.Tracks[:min(homeChart, len(chart.Tracks))]
			g.player.mu.Lock()
			ev["chart"] = g.player.shapeAll(top)
			g.player.mu.Unlock()
		}
		g.emit(ev)
	}()
}
