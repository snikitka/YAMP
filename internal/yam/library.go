package yam

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type trackRef struct {
	ID      flexID `json:"id"`
	AlbumID flexID `json:"albumId"`
}

func (r trackRef) id() string {
	id := string(r.ID)
	if i := strings.IndexByte(id, ':'); i > 0 {
		id = id[:i]
	}
	return id
}

func userPath(uid int64) string {
	return "/users/" + strconv.FormatInt(uid, 10)
}

func (c *Client) trackRefs(ctx context.Context, path string) ([]string, error) {
	var r struct {
		Library struct {
			Tracks []trackRef `json:"tracks"`
		} `json:"library"`
	}
	if err := c.api(ctx, http.MethodGet, path, nil, &r); err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(r.Library.Tracks))
	for _, t := range r.Library.Tracks {
		if id := t.id(); id != "" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

func (c *Client) LikedTrackIDs(ctx context.Context, uid int64) ([]string, error) {
	return c.trackRefs(ctx, userPath(uid)+"/likes/tracks")
}

const LikedLink = "liked"

func (c *Client) ResolveLiked(ctx context.Context, uid int64) (*Release, error) {
	ids, err := c.LikedTrackIDs(ctx, uid)
	if err != nil {
		return nil, err
	}
	list, err := c.fetchTracks(ctx, ids)
	if err != nil {
		return nil, err
	}
	r := &Release{Kind: KindPlaylist, Title: "Мне нравится"}
	for _, t := range list {
		if tr := t.shape(nil); tr.ID != "" {
			r.Tracks = append(r.Tracks, tr)
		}
	}
	r.TrackCount = len(r.Tracks)
	return r, nil
}

func (c *Client) DislikedTrackIDs(ctx context.Context, uid int64) ([]string, error) {
	return c.trackRefs(ctx, userPath(uid)+"/dislikes/tracks")
}

func (c *Client) markTracks(ctx context.Context, uid int64, list string, ids []string, on bool) error {
	action := "/add-multiple"
	if !on {
		action = "/remove"
	}
	form := url.Values{"track-ids": {strings.Join(ids, ",")}}
	var out any
	return c.api(ctx, http.MethodPost, userPath(uid)+"/"+list+"/tracks"+action, form, &out)
}

func (c *Client) LikeTracks(ctx context.Context, uid int64, ids []string, on bool) error {
	return c.markTracks(ctx, uid, "likes", ids, on)
}

func (c *Client) DislikeTracks(ctx context.Context, uid int64, ids []string, on bool) error {
	return c.markTracks(ctx, uid, "dislikes", ids, on)
}

func (c *Client) UserPlaylists(ctx context.Context, uid int64) ([]Hit, error) {
	var list []apiSearchPlaylist
	if err := c.api(ctx, http.MethodGet, userPath(uid)+"/playlists/list", nil, &list); err != nil {
		return nil, err
	}
	return playlistHits(list), nil
}

func (c *Client) LikedPlaylists(ctx context.Context, uid int64) ([]Hit, error) {
	var likes []struct {
		Playlist *apiSearchPlaylist `json:"playlist"`
	}
	if err := c.api(ctx, http.MethodGet, userPath(uid)+"/likes/playlists", nil, &likes); err != nil {
		return nil, err
	}
	list := make([]apiSearchPlaylist, 0, len(likes))
	for _, l := range likes {
		if l.Playlist != nil {
			list = append(list, *l.Playlist)
		}
	}
	return playlistHits(list), nil
}

func playlistHits(list []apiSearchPlaylist) []Hit {
	out := make([]Hit, 0, len(list))
	for _, p := range list {
		if h := playlistHit(p); h.Link != "" {
			out = append(out, h)
		}
	}
	return out
}

const trackBatch = 200

const artistTop = 50

func (c *Client) ArtistPage(ctx context.Context, artistID string) (*Release, error) {
	r, err := c.resolveArtist(ctx, artistID, false, nil)
	if err != nil {
		return nil, err
	}
	var top struct {
		Tracks []apiTrack `json:"tracks"`
	}
	path := "/artists/" + url.PathEscape(artistID) + "/tracks?page=0&page-size=" + strconv.Itoa(artistTop)
	if err := c.api(ctx, http.MethodGet, path, nil, &top); err != nil {
		return nil, err
	}
	for _, t := range top.Tracks {
		if tr := t.shape(nil); tr.ID != "" {
			r.Tracks = append(r.Tracks, tr)
		}
	}
	return r, nil
}

func (c *Client) Tracks(ctx context.Context, ids []string) ([]Track, error) {
	var batches [][]string
	for len(ids) > 0 {
		n := min(len(ids), trackBatch)
		batches = append(batches, ids[:n])
		ids = ids[n:]
	}
	got := make([][]apiTrack, len(batches))
	errs := make([]error, len(batches))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for i, b := range batches {
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
			got[i], errs[i] = c.fetchTracks(ctx, b)
		}()
	}
	wg.Wait()
	var out []Track
	for i, list := range got {
		if errs[i] != nil {
			return nil, errs[i]
		}
		for _, t := range list {
			if tr := t.shape(nil); tr.ID != "" {
				out = append(out, tr)
			}
		}
	}
	return out, nil
}

type Play struct {
	Track    Track
	From     string
	Playlist string
	Played   float64
	Position float64
}

func (c *Client) ReportPlay(ctx context.Context, uid int64, p Play) error {
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	form := url.Values{
		"track-id":             {p.Track.ID},
		"from-cache":           {"False"},
		"from":                 {p.From},
		"play-id":              {playID()},
		"uid":                  {strconv.FormatInt(uid, 10)},
		"timestamp":            {now},
		"track-length-seconds": {seconds(float64(p.Track.Duration) / 1000)},
		"total-played-seconds": {seconds(p.Played)},
		"end-position-seconds": {seconds(p.Position)},
		"album-id":             {p.Track.AlbumID},
		"playlist-id":          {p.Playlist},
		"client-now":           {now},
	}
	var out any
	return c.api(ctx, http.MethodPost, "/play-audio", form, &out)
}

func seconds(v float64) string {
	return strconv.FormatFloat(max(v, 0), 'f', 2, 64)
}

func playID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
