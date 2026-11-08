package yam

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
)

type Track struct {
	ID          string
	AlbumID     string
	Title       string
	Artists     string
	ArtistRefs  []ArtistRef
	Album       string
	AlbumArtist string
	Year        int
	Genre       string
	Number      int
	Disc        int
	TrackTotal  int
	DiscTotal   int
	Cover       string
	Duration    int
	Available   bool
	Explicit    bool
	Lyrics      LyricsKind
}

type ArtistRef struct {
	ID   string
	Name string
}

type Release struct {
	Kind       Kind
	Title      string
	Artist     string
	Artists    []ArtistRef
	Year       int
	Cover      string
	TrackCount int
	Tracks     []Track
	Albums     []AlbumInfo
	Explicit   bool
}

type apiArtist struct {
	ID      flexID `json:"id"`
	Name    string `json:"name"`
	Various bool   `json:"various"`
}

type apiAlbum struct {
	ID         flexID      `json:"id"`
	Title      string      `json:"title"`
	Version    string      `json:"version"`
	Year       flexInt     `json:"year"`
	Genre      string      `json:"genre"`
	TrackCount int         `json:"trackCount"`
	Type       string      `json:"type"`
	MetaType   string      `json:"metaType"`
	Warning    string      `json:"contentWarning"`
	CoverURI   string      `json:"coverUri"`
	Artists    []apiArtist `json:"artists"`
	TrackPos   *struct {
		Volume int `json:"volume"`
		Index  int `json:"index"`
	} `json:"trackPosition"`
	Volumes [][]apiTrack `json:"volumes"`
}

type apiTrack struct {
	ID        flexID         `json:"id"`
	RealID    flexID         `json:"realId"`
	Title     string         `json:"title"`
	Version   string         `json:"version"`
	Available *bool          `json:"available"`
	CoverURI  string         `json:"coverUri"`
	Artists   []apiArtist    `json:"artists"`
	Albums    []apiAlbum     `json:"albums"`
	Warning   string         `json:"contentWarning"`
	Explicit  bool           `json:"explicit"`
	Duration  int            `json:"durationMs"`
	Source    string         `json:"trackSource"`
	Lyrics    *apiLyricsInfo `json:"lyricsInfo"`
}

var uploadExts = []string{".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".wav"}

func uploadTitle(title string) string {
	lower := strings.ToLower(title)
	for _, ext := range uploadExts {
		if strings.HasSuffix(lower, ext) && len(title) > len(ext) {
			return strings.TrimSpace(title[:len(title)-len(ext)])
		}
	}
	return title
}

func joinArtists(artists []apiArtist) string {
	names := make([]string, 0, len(artists))
	for _, a := range artists {
		if n := strings.TrimSpace(a.Name); n != "" {
			names = append(names, n)
		}
	}
	return strings.Join(names, ", ")
}

func artistRefs(artists []apiArtist) []ArtistRef {
	var out []ArtistRef
	for _, a := range artists {
		n := strings.TrimSpace(a.Name)
		if a.ID == "" || a.ID == "0" || n == "" || a.Various {
			continue
		}
		out = append(out, ArtistRef{ID: string(a.ID), Name: n})
	}
	return out
}

func (a apiAlbum) info(id string) AlbumInfo {
	if a.ID != "" {
		id = string(a.ID)
	}
	return AlbumInfo{
		ID:         id,
		Title:      withVersion(a.Title, a.Version),
		Year:       int(a.Year),
		Cover:      a.CoverURI,
		TrackCount: a.TrackCount,
		Type:       albumType(a.Type),
		Explicit:   a.Warning == "explicit",
	}
}

func withVersion(title, version string) string {
	title, version = strings.TrimSpace(title), strings.TrimSpace(version)
	if version == "" || strings.Contains(strings.ToLower(title), strings.ToLower(version)) {
		return title
	}
	return title + " (" + version + ")"
}

func (t apiTrack) shape(album *apiAlbum) Track {
	if album == nil && len(t.Albums) > 0 {
		album = &t.Albums[0]
	}
	if album == nil {
		album = &apiAlbum{}
	}
	id := string(t.ID)
	if id == "" {
		id = string(t.RealID)
	}

	if i := strings.IndexByte(id, ':'); i > 0 {
		id = id[:i]
	}
	artists := joinArtists(t.Artists)
	albumTitle := withVersion(album.Title, album.Version)
	if artists == "" {

		artists = albumTitle
	}
	title := t.Title
	if t.Source == "UGC" {
		title = uploadTitle(title)
	}
	tr := Track{
		ID:          id,
		AlbumID:     string(album.ID),
		Title:       withVersion(title, t.Version),
		Artists:     artists,
		ArtistRefs:  artistRefs(t.Artists),
		Album:       albumTitle,
		AlbumArtist: joinArtists(album.Artists),
		Year:        int(album.Year),
		Genre:       album.Genre,
		TrackTotal:  album.TrackCount,
		Cover:       t.CoverURI,
		Duration:    t.Duration,
		Available:   t.Available == nil || *t.Available,
		Explicit:    t.Explicit || t.Warning == "explicit",
		Lyrics:      t.Lyrics.kind(),
	}
	if tr.Cover == "" {
		tr.Cover = album.CoverURI
	}
	if album.TrackPos != nil {
		tr.Number = album.TrackPos.Index
		tr.Disc = album.TrackPos.Volume
	}
	return tr
}

func CoverURL(uri, size string) string {
	if uri == "" {
		return ""
	}
	if !strings.HasPrefix(uri, "http") {
		uri = "https://" + uri
	}
	return strings.Replace(uri, "%%", size, 1)
}

func (c *Client) Resolve(ctx context.Context, l Link, withTracks bool) (*Release, error) {
	switch l.Kind {
	case KindTrack:
		return c.resolveTrack(ctx, l)
	case KindAlbum:
		return c.resolveAlbum(ctx, l.AlbumID, withTracks)
	case KindPlaylist:
		return c.resolvePlaylist(ctx, l, withTracks)
	case KindArtist:
		return c.resolveArtist(ctx, l.ArtistID, withTracks, nil)
	}
	return nil, errBadLink
}

func (c *Client) fetchTracks(ctx context.Context, ids []string) ([]apiTrack, error) {
	var out []apiTrack
	for len(ids) > 0 {
		n := min(len(ids), 200)
		var batch []apiTrack
		form := url.Values{"track-ids": {strings.Join(ids[:n], ",")}}
		if err := c.api(ctx, http.MethodPost, "/tracks", form, &batch); err != nil {
			return nil, err
		}
		out = append(out, batch...)
		ids = ids[n:]
	}
	return out, nil
}

func (c *Client) resolveTrack(ctx context.Context, l Link) (*Release, error) {
	list, err := c.fetchTracks(ctx, []string{l.TrackID})
	if err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, fmt.Errorf("трек %s не найден", l.TrackID)
	}
	t := list[0]
	var album *apiAlbum
	for i := range t.Albums {
		if string(t.Albums[i].ID) == l.AlbumID {
			album = &t.Albums[i]
		}
	}
	tr := t.shape(album)
	return &Release{
		Kind:       KindTrack,
		Title:      tr.Title,
		Artist:     tr.Artists,
		Artists:    tr.ArtistRefs,
		Year:       tr.Year,
		Cover:      tr.Cover,
		TrackCount: 1,
		Tracks:     []Track{tr},
		Explicit:   tr.Explicit,
	}, nil
}

func (c *Client) resolveAlbum(ctx context.Context, albumID string, withTracks bool) (*Release, error) {
	path := "/albums/" + albumID
	if withTracks {
		path += "/with-tracks"
	}
	var a apiAlbum
	if err := c.api(ctx, http.MethodGet, path, nil, &a); err != nil {
		return nil, err
	}
	r := &Release{
		Kind:       KindAlbum,
		Title:      withVersion(a.Title, a.Version),
		Artist:     joinArtists(a.Artists),
		Artists:    artistRefs(a.Artists),
		Year:       int(a.Year),
		Cover:      a.CoverURI,
		TrackCount: a.TrackCount,
		Explicit:   a.Warning == "explicit",
	}
	if r.Title == "" {
		r.Title = "Альбом " + albumID
	}
	discs := len(a.Volumes)
	for d, vol := range a.Volumes {
		for i, t := range vol {
			tr := t.shape(&a)

			tr.Number, tr.Disc, tr.DiscTotal = i+1, d+1, discs
			tr.TrackTotal = len(vol)
			if tr.ID != "" {
				r.Tracks = append(r.Tracks, tr)
			}
		}
	}
	for _, t := range r.Tracks {
		r.Explicit = r.Explicit || t.Explicit
	}
	if withTracks {
		r.TrackCount = len(r.Tracks)
	}
	info := a.info(albumID)
	info.Title, info.TrackCount, info.Explicit = r.Title, r.TrackCount, r.Explicit
	r.Albums = []AlbumInfo{info}
	return r, nil
}

func (c *Client) resolvePlaylist(ctx context.Context, l Link, withTracks bool) (*Release, error) {
	path := "/users/" + url.PathEscape(l.Owner) + "/playlists/" + l.PlaylistKind
	if l.UUID != "" {
		path = "/playlist/" + l.UUID
	}
	var p struct {
		Title      string `json:"title"`
		TrackCount int    `json:"trackCount"`
		OgImage    string `json:"ogImage"`
		Owner      struct {
			Login string `json:"login"`
			Name  string `json:"name"`
		} `json:"owner"`
		Cover struct {
			URI      string   `json:"uri"`
			ItemsURI []string `json:"itemsUri"`
		} `json:"cover"`
		Tracks []struct {
			ID      flexID    `json:"id"`
			AlbumID flexID    `json:"albumId"`
			Track   *apiTrack `json:"track"`
		} `json:"tracks"`
	}
	if err := c.api(ctx, http.MethodGet, path, nil, &p); err != nil {
		return nil, err
	}
	r := &Release{
		Kind:       KindPlaylist,
		Title:      strings.TrimSpace(p.Title),
		Artist:     p.Owner.Name,
		Cover:      p.Cover.URI,
		TrackCount: p.TrackCount,
	}
	if r.Artist == "" {
		r.Artist = p.Owner.Login
	}
	if r.Cover == "" && len(p.Cover.ItemsURI) > 0 {
		r.Cover = p.Cover.ItemsURI[0]
	}
	if r.Cover == "" {
		r.Cover = p.OgImage
	}
	if r.Title == "" {
		r.Title = "Плейлист"
	}
	if r.TrackCount == 0 {
		r.TrackCount = len(p.Tracks)
	}
	if !withTracks {
		return r, nil
	}

	shaped := make([]*Track, len(p.Tracks))
	var missing []string
	where := map[string][]int{}
	for i, it := range p.Tracks {
		if it.Track != nil && it.Track.Title != "" {
			tr := it.Track.shape(nil)
			shaped[i] = &tr
			continue
		}
		if id := string(it.ID); id != "" {
			if i := strings.IndexByte(id, ':'); i > 0 {
				id = id[:i]
			}
			if _, ok := where[id]; !ok {
				missing = append(missing, id)
			}
			where[id] = append(where[id], i)
		}
	}
	if len(missing) > 0 {
		list, err := c.fetchTracks(ctx, missing)
		if err != nil {
			return nil, err
		}
		for _, t := range list {
			tr := t.shape(nil)
			for _, i := range where[tr.ID] {
				cp := tr
				shaped[i] = &cp
			}
		}
	}
	for _, tr := range shaped {
		if tr != nil && tr.ID != "" {
			r.Tracks = append(r.Tracks, *tr)
		}
	}
	r.TrackCount = len(r.Tracks)
	return r, nil
}

type AlbumInfo struct {
	ID         string
	Title      string
	Year       int
	Cover      string
	TrackCount int
	Type       string
	Explicit   bool
}

type Selection map[string][]string

func (c *Client) artistAlbums(ctx context.Context, artistID string) ([]AlbumInfo, error) {
	var out []AlbumInfo
	for page := 0; ; page++ {
		var res struct {
			Albums []apiAlbum `json:"albums"`
			Pager  struct {
				Total int `json:"total"`
			} `json:"pager"`
		}
		path := fmt.Sprintf("/artists/%s/direct-albums?page=%d&page-size=100&sort-by=year", artistID, page)
		if err := c.api(ctx, http.MethodGet, path, nil, &res); err != nil {
			return nil, err
		}
		for _, a := range res.Albums {
			if a.ID == "" {
				continue
			}
			out = append(out, a.info(""))
		}
		if len(res.Albums) == 0 || len(out) >= res.Pager.Total {
			break
		}
	}
	return out, nil
}

func albumType(t string) string {
	switch t {
	case "single":
		return "single"
	case "compilation":
		return "compilation"
	}
	return "album"
}

func (c *Client) AlbumTracks(ctx context.Context, albumID string) ([]Track, error) {
	r, err := c.resolveAlbum(ctx, albumID, true)
	if err != nil {
		return nil, err
	}
	return r.Tracks, nil
}

func (c *Client) ResolveSelected(ctx context.Context, l Link, sel Selection) (*Release, error) {
	switch {
	case len(sel) == 0:
		return c.Resolve(ctx, l, true)
	case l.Kind == KindAlbum:
		r, err := c.resolveAlbum(ctx, l.AlbumID, true)
		if err != nil {
			return nil, err
		}
		r.Tracks = pick(r.Tracks, sel[l.AlbumID])
		r.TrackCount = len(r.Tracks)
		return r, nil
	case l.Kind == KindArtist:
		return c.resolveArtist(ctx, l.ArtistID, true, sel)
	case l.Kind == KindPlaylist:
		r, err := c.resolvePlaylist(ctx, l, true)
		if err != nil {
			return nil, err
		}
		var ids []string
		for _, t := range sel {
			ids = append(ids, t...)
		}
		r.Tracks = pick(r.Tracks, ids)
		r.TrackCount = len(r.Tracks)
		return r, nil
	}
	return c.Resolve(ctx, l, true)
}

func (c *Client) resolveArtist(ctx context.Context, artistID string, withTracks bool, sel Selection) (*Release, error) {
	var info struct {
		Artist struct {
			Name  string `json:"name"`
			Cover struct {
				URI string `json:"uri"`
			} `json:"cover"`
			Counts struct {
				Tracks int `json:"tracks"`
			} `json:"counts"`
		} `json:"artist"`
	}
	if err := c.api(ctx, http.MethodGet, "/artists/"+artistID+"/brief-info", nil, &info); err != nil {
		return nil, err
	}
	r := &Release{
		Kind:       KindArtist,
		Title:      info.Artist.Name,
		Artist:     info.Artist.Name,
		Cover:      info.Artist.Cover.URI,
		TrackCount: info.Artist.Counts.Tracks,
	}
	if r.Title == "" {
		r.Title = "Исполнитель " + artistID
	}
	albums, err := c.artistAlbums(ctx, artistID)
	if err != nil {
		return nil, err
	}
	if !withTracks {
		r.Albums = albums
		return r, nil
	}

	var ids []string
	for _, a := range albums {
		if _, ok := sel[a.ID]; sel == nil || ok {
			ids = append(ids, a.ID)
		}
	}
	for id := range sel {
		if !slices.Contains(ids, id) {
			ids = append(ids, id)
		}
	}

	resolved := make([]*Release, len(ids))
	errs := make([]error, len(ids))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 6)
	for i, id := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				errs[i] = ctx.Err()
				return
			}
			defer func() { <-sem }()
			resolved[i], errs[i] = c.resolveAlbum(ctx, id, true)
		}()
	}
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	for i, a := range resolved {
		if errs[i] != nil || a == nil {
			continue
		}
		r.Tracks = append(r.Tracks, pick(a.Tracks, sel[ids[i]])...)
	}
	if len(r.Tracks) == 0 && len(ids) > 0 {
		for _, err := range errs {
			if err != nil {
				return nil, fmt.Errorf("не удалось получить альбомы исполнителя: %v", err)
			}
		}
	}
	r.TrackCount = len(r.Tracks)
	return r, nil
}

func pick(tracks []Track, ids []string) []Track {
	if len(ids) == 0 {
		return tracks
	}
	var out []Track
	for _, t := range tracks {
		if slices.Contains(ids, t.ID) {
			out = append(out, t)
		}
	}
	return out
}
