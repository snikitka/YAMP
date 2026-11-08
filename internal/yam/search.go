package yam

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const webBase = "https://music.yandex.ru"

type Hit struct {
	Kind     Kind
	ID       string
	Title    string
	Artist   string
	Album    string
	Year     int
	Cover    string
	Count    int
	Type     string
	Duration int
	Explicit bool
	Link     string
}

type Section struct {
	Total   int
	PerPage int
	Hits    []Hit
}

type SearchResult struct {
	Text      string
	Corrected string
	Best      *Hit
	Sections  map[Kind]*Section
}

var searchTypes = map[Kind]string{
	KindTrack:    "track",
	KindAlbum:    "album",
	KindArtist:   "artist",
	KindPlaylist: "playlist",
}

type apiSearchArtist struct {
	ID    flexID `json:"id"`
	Name  string `json:"name"`
	Cover struct {
		URI string `json:"uri"`
	} `json:"cover"`
	OgImage string   `json:"ogImage"`
	Genres  []string `json:"genres"`
	Counts  struct {
		Tracks int `json:"tracks"`
	} `json:"counts"`
}

type apiSearchPlaylist struct {
	UID   flexID `json:"uid"`
	Kind  flexID `json:"kind"`
	UUID  string `json:"playlistUuid"`
	Title string `json:"title"`
	Owner struct {
		UID   flexID `json:"uid"`
		Login string `json:"login"`
		Name  string `json:"name"`
	} `json:"owner"`
	TrackCount int `json:"trackCount"`
	Cover      struct {
		URI      string   `json:"uri"`
		ItemsURI []string `json:"itemsUri"`
	} `json:"cover"`
	OgImage string `json:"ogImage"`
}

type apiSearchTrack struct {
	apiTrack
	DurationMs int `json:"durationMs"`
}

type rawSection[T any] struct {
	Total   int `json:"total"`
	PerPage int `json:"perPage"`
	Results []T `json:"results"`
}

func (c *Client) Search(ctx context.Context, text string, kind Kind, page int) (*SearchResult, error) {
	typ := "all"
	if t, ok := searchTypes[kind]; ok {
		typ = t
	}
	q := url.Values{
		"text":      {text},
		"type":      {typ},
		"page":      {strconv.Itoa(page)},
		"nocorrect": {"false"},
	}
	var r struct {
		Text              string `json:"text"`
		MisspellCorrected bool   `json:"misspellCorrected"`
		MisspellResult    string `json:"misspellResult"`
		Best              *struct {
			Type   string          `json:"type"`
			Result json.RawMessage `json:"result"`
		} `json:"best"`
		Tracks    *rawSection[apiTrack]          `json:"tracks"`
		Albums    *rawSection[apiAlbum]          `json:"albums"`
		Artists   *rawSection[apiSearchArtist]   `json:"artists"`
		Playlists *rawSection[apiSearchPlaylist] `json:"playlists"`
	}
	if err := c.api(ctx, http.MethodGet, "/search?"+q.Encode(), nil, &r); err != nil {
		return nil, err
	}
	res := &SearchResult{Text: r.Text, Sections: map[Kind]*Section{}}
	if r.MisspellResult != "" && !strings.EqualFold(r.MisspellResult, text) {
		res.Corrected = r.MisspellResult
	}
	if r.Tracks != nil {
		res.Sections[KindTrack] = section(r.Tracks, func(t apiTrack) Hit { return trackHit(t) })
	}
	if r.Albums != nil {
		res.Sections[KindAlbum] = section(r.Albums, albumHit)
	}
	if r.Artists != nil {
		res.Sections[KindArtist] = section(r.Artists, artistHit)
	}
	if r.Playlists != nil {
		res.Sections[KindPlaylist] = section(r.Playlists, playlistHit)
	}
	if r.Best != nil {
		res.Best = bestHit(r.Best.Type, r.Best.Result)
	}
	return res, nil
}

func section[T any](raw *rawSection[T], shape func(T) Hit) *Section {
	s := &Section{Total: raw.Total, PerPage: raw.PerPage}
	for _, it := range raw.Results {
		if h := shape(it); h.Link != "" {
			s.Hits = append(s.Hits, h)
		}
	}
	return s
}

func bestHit(typ string, raw json.RawMessage) *Hit {
	var h Hit
	switch typ {
	case "track":
		var t apiTrack
		if json.Unmarshal(raw, &t) != nil {
			return nil
		}
		h = trackHit(t)
	case "album":
		var a apiAlbum
		if json.Unmarshal(raw, &a) != nil {
			return nil
		}
		h = albumHit(a)
	case "artist":
		var a apiSearchArtist
		if json.Unmarshal(raw, &a) != nil {
			return nil
		}
		h = artistHit(a)
	case "playlist":
		var p apiSearchPlaylist
		if json.Unmarshal(raw, &p) != nil {
			return nil
		}
		h = playlistHit(p)
	default:
		return nil
	}
	if h.Link == "" {
		return nil
	}
	return &h
}

func trackHit(t apiTrack) Hit {
	if len(t.Albums) > 0 && t.Albums[0].MetaType == "podcast" {
		return Hit{}
	}
	tr := t.shape(nil)
	h := Hit{
		Kind:     KindTrack,
		ID:       tr.ID,
		Title:    tr.Title,
		Artist:   tr.Artists,
		Album:    tr.Album,
		Year:     tr.Year,
		Cover:    tr.Cover,
		Count:    1,
		Duration: tr.Duration / 1000,
		Explicit: tr.Explicit,
	}
	switch {
	case tr.ID == "":
	case tr.AlbumID != "":
		h.Link = webBase + "/album/" + tr.AlbumID + "/track/" + tr.ID
	default:
		h.Link = webBase + "/track/" + tr.ID
	}
	return h
}

func albumHit(a apiAlbum) Hit {
	if a.ID == "" || a.MetaType == "podcast" {
		return Hit{}
	}
	info := a.info("")
	return Hit{
		Kind:     KindAlbum,
		ID:       info.ID,
		Title:    info.Title,
		Artist:   joinArtists(a.Artists),
		Year:     info.Year,
		Cover:    info.Cover,
		Count:    info.TrackCount,
		Type:     info.Type,
		Explicit: info.Explicit,
		Link:     webBase + "/album/" + info.ID,
	}
}

func artistHit(a apiSearchArtist) Hit {
	if a.ID == "" {
		return Hit{}
	}
	cover := a.Cover.URI
	if cover == "" {
		cover = a.OgImage
	}
	return Hit{
		Kind:  KindArtist,
		ID:    string(a.ID),
		Title: strings.TrimSpace(a.Name),
		Cover: cover,
		Count: a.Counts.Tracks,
		Type:  strings.Join(a.Genres, ", "),
		Link:  webBase + "/artist/" + string(a.ID),
	}
}

func playlistHit(p apiSearchPlaylist) Hit {
	owner := p.Owner.Login
	if owner == "" {
		owner = string(p.Owner.UID)
	}
	if owner == "" {
		owner = string(p.UID)
	}
	h := Hit{
		Kind:   KindPlaylist,
		Title:  strings.TrimSpace(p.Title),
		Artist: p.Owner.Name,
		Count:  p.TrackCount,
		Cover:  p.Cover.URI,
	}
	if h.Artist == "" {
		h.Artist = p.Owner.Login
	}
	if h.Cover == "" && len(p.Cover.ItemsURI) > 0 {
		h.Cover = p.Cover.ItemsURI[0]
	}
	if h.Cover == "" {
		h.Cover = p.OgImage
	}
	switch {
	case owner != "" && p.Kind != "":
		h.ID = owner + "/" + string(p.Kind)
		h.Link = webBase + "/users/" + url.PathEscape(owner) + "/playlists/" + string(p.Kind)
	case p.UUID != "":
		h.ID = p.UUID
		h.Link = webBase + "/playlists/" + p.UUID
	}
	return h
}
