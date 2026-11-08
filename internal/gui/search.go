package gui

import (
	"context"
	"errors"
	"time"

	"yamp/internal/yam"
)

type searchHit struct {
	Kind     string `json:"kind"`
	ID       string `json:"id"`
	Title    string `json:"title"`
	Artist   string `json:"artist,omitempty"`
	Album    string `json:"album,omitempty"`
	Year     int    `json:"year,omitempty"`
	Cover    string `json:"cover,omitempty"`
	Count    int    `json:"count,omitempty"`
	Type     string `json:"type,omitempty"`
	Duration int    `json:"duration,omitempty"`
	Explicit bool   `json:"explicit,omitempty"`
	Link     string `json:"link"`
}

type searchSection struct {
	Total int         `json:"total"`
	More  bool        `json:"more"`
	Hits  []searchHit `json:"hits"`
}

type searchEvent struct {
	Type      string                    `json:"type"`
	Seq       int                       `json:"seq"`
	Query     string                    `json:"query"`
	Kind      string                    `json:"kind"`
	Page      int                       `json:"page"`
	Status    string                    `json:"status"`
	Message   string                    `json:"message,omitempty"`
	Corrected string                    `json:"corrected,omitempty"`
	Best      *searchHit                `json:"best,omitempty"`
	Sections  map[string]*searchSection `json:"sections,omitempty"`
}

func hitEvent(h yam.Hit) searchHit {
	return searchHit{
		Kind: string(h.Kind), ID: h.ID, Title: h.Title, Artist: h.Artist, Album: h.Album,
		Year: h.Year, Cover: yam.CoverURL(h.Cover, "200x200"), Count: h.Count, Type: h.Type,
		Duration: h.Duration, Explicit: h.Explicit, Link: h.Link,
	}
}

func (g *App) search(seq int, query, kind string, page int) {
	g.mu.Lock()
	token := g.token
	if g.searchCancel != nil {
		g.searchCancel()
		g.searchCancel = nil
	}
	g.mu.Unlock()

	ev := searchEvent{Type: "search", Seq: seq, Query: query, Kind: kind, Page: page}
	if query == "" {
		return
	}
	if token == "" {
		ev.Status, ev.Message = "error", yam.ErrUnauthorized.Error()
		g.emit(ev)
		return
	}
	k := yam.Kind(kind)
	switch k {
	case "", yam.KindTrack, yam.KindAlbum, yam.KindArtist, yam.KindPlaylist:
	default:
		ev.Status, ev.Message = "error", "неизвестный раздел поиска"
		g.emit(ev)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	g.mu.Lock()
	g.searchCancel = cancel
	g.mu.Unlock()

	go func() {
		defer cancel()
		res, err := yam.New(token).Search(ctx, query, k, max(page, 0))
		if errors.Is(err, context.Canceled) {
			return
		}
		if err != nil {
			ev.Status, ev.Message = "error", searchError(err)
			g.emit(ev)
			return
		}
		ev.Status, ev.Corrected = "ok", res.Corrected
		if res.Best != nil {
			b := hitEvent(*res.Best)
			ev.Best = &b
		}
		ev.Sections = map[string]*searchSection{}
		for kind, s := range res.Sections {
			out := &searchSection{Total: s.Total, Hits: make([]searchHit, 0, len(s.Hits))}
			for _, h := range s.Hits {
				out.Hits = append(out.Hits, hitEvent(h))
			}
			out.More = s.PerPage > 0 && (page+1)*s.PerPage < s.Total
			ev.Sections[string(kind)] = out
		}
		g.emit(ev)
	}()
}

func searchError(err error) string {
	var api *yam.APIError
	switch {
	case errors.Is(err, yam.ErrUnauthorized):
		return err.Error()
	case errors.As(err, &api):
		return "Яндекс Музыка ответила ошибкой (" + api.Error() + "). Повторите чуть позже."
	case errors.Is(err, context.DeadlineExceeded):
		return "Яндекс Музыка не ответила вовремя. Проверьте подключение и повторите."
	}
	return "Нет связи с Яндекс Музыкой. Проверьте подключение и повторите."
}
