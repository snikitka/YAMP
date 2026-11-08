package yam

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestStreamerRangeDecrypt(t *testing.T) {
	key := bytes.Repeat([]byte{0x24}, 16)
	plain := make([]byte, 300000)
	for i := range plain {
		plain[i] = byte(i * 7)
	}
	block, _ := aes.NewCipher(key)
	enc := make([]byte, len(plain))
	cipher.NewCTR(block, make([]byte, 16)).XORKeyStream(enc, plain)

	var infos, denied atomic.Int32
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/get-file-info":
			n := infos.Add(1)
			if id := r.URL.Query().Get("trackId"); id != "77" && id != "40279b37-a47c-4877-9e89-46e9fd397e3d" {
				http.NotFound(w, r)
				return
			}
			file := "/file/old"
			if n > 1 {
				file = "/file/new"
			}
			json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"downloadInfo": map[string]any{
				"codec": "flac-mp4", "bitrate": 0, "key": hex.EncodeToString(key), "urls": []string{srv.URL + file},
			}}})
		case r.URL.Path == "/file/old":
			denied.Add(1)
			w.WriteHeader(http.StatusForbidden)
		case r.URL.Path == "/file/new":
			http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(enc))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	c := New("t")
	c.base = srv.URL
	s := NewStreamer()
	s.SetClient(c)
	local := httptest.NewServer(s)
	defer local.Close()

	get := func(rng string) (*http.Response, []byte) {
		req, _ := http.NewRequest(http.MethodGet, local.URL+"/77?q=lossless", nil)
		if rng != "" {
			req.Header.Set("Range", rng)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp, b
	}

	resp, body := get("")
	if resp.StatusCode != http.StatusOK || !bytes.Equal(body, plain) {
		t.Fatalf("целиком: status=%d len=%d", resp.StatusCode, len(body))
	}
	if ct := resp.Header.Get("Content-Type"); ct != "audio/mp4" {
		t.Errorf("Content-Type = %q", ct)
	}
	if denied.Load() != 1 || infos.Load() != 2 {
		t.Errorf("протухшая ссылка: отказов %d, запросов get-file-info %d", denied.Load(), infos.Load())
	}

	for _, start := range []int{1, 15, 16, 4099, 299990} {
		resp, body := get("bytes=" + strconv.Itoa(start) + "-")
		if resp.StatusCode != http.StatusPartialContent || !bytes.Equal(body, plain[start:]) {
			t.Errorf("с байта %d: status=%d len=%d", start, resp.StatusCode, len(body))
		}
	}
	resp, body = get("bytes=100-131")
	if !bytes.Equal(body, plain[100:132]) || resp.Header.Get("Content-Range") != "bytes 100-131/300000" {
		t.Errorf("кусок: %q", resp.Header.Get("Content-Range"))
	}
	if infos.Load() != 2 {
		t.Errorf("ссылка не закешировалась: %d запросов", infos.Load())
	}

	f, err := s.Prepare(context.Background(), "77", Lossless)
	if err != nil || !f.Lossless || f.String() != "FLAC" {
		t.Errorf("формат = %+v %v", f, err)
	}

	if r, _ := get(""); r.StatusCode != http.StatusOK {
		t.Fatal(r.StatusCode)
	}
	if r, _ := http.Get(local.URL + "/40279b37-a47c-4877-9e89-46e9fd397e3d?q=lossless"); r == nil || r.StatusCode != http.StatusOK {
		t.Errorf("загруженный пользователем трек не отдаётся")
	}
	req, _ := http.NewRequest(http.MethodGet, local.URL+"/a%20b", nil)
	if r, err := http.DefaultClient.Do(req); err != nil || r.StatusCode != http.StatusNotFound {
		t.Errorf("кривой id: %v", r.StatusCode)
	}
	s.SetClient(nil)
	if r, _ := get(""); r.StatusCode != http.StatusUnauthorized {
		t.Errorf("без сессии: %d", r.StatusCode)
	}
}

func TestLibraryCalls(t *testing.T) {
	var posted []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/users/5/likes/tracks":
			w.Write([]byte(`{"result":{"library":{"tracks":[{"id":"10","albumId":"1"},{"id":"11:2"},{"id":""}]}}}`))
		case "/users/5/dislikes/tracks":
			w.Write([]byte(`{"result":{"library":{"tracks":[{"id":12}]}}}`))
		case "/users/5/playlists/list":
			w.Write([]byte(`{"result":[{"uid":5,"kind":1001,"title":"Дорога","trackCount":3,"owner":{"uid":5,"login":"me","name":"Я"}}]}`))
		case "/users/5/likes/playlists":
			w.Write([]byte(`{"result":[{"playlist":{"playlistUuid":"lk.abcdefabcdefabcdefabcdefabcdefab","title":"Чужой"}},{}]}`))
		case "/users/5/likes/tracks/add-multiple", "/users/5/dislikes/tracks/remove", "/play-audio":
			r.ParseForm()
			posted = append(posted, r.URL.Path+"?"+r.PostForm.Get("track-ids")+r.PostForm.Get("track-id"))
			w.Write([]byte(`{"result":{"revision":2}}`))
		case "/tracks":
			r.ParseForm()
			var items []string
			for _, id := range strings.Split(r.PostForm.Get("track-ids"), ",") {
				items = append(items, `{"id":"`+id+`","title":"T`+id+`","durationMs":181000,"albums":[{"id":9}]}`)
			}
			w.Write([]byte(`{"result":[` + strings.Join(items, ",") + `]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c := New("t")
	c.base = srv.URL
	ctx := context.Background()

	liked, err := c.LikedTrackIDs(ctx, 5)
	if err != nil || strings.Join(liked, ",") != "10,11" {
		t.Fatalf("лайки = %v %v", liked, err)
	}
	disliked, err := c.DislikedTrackIDs(ctx, 5)
	if err != nil || strings.Join(disliked, ",") != "12" {
		t.Fatalf("дизлайки = %v %v", disliked, err)
	}
	rel, err := c.ResolveLiked(ctx, 5)
	if err != nil || rel.Kind != KindPlaylist || rel.Folder() != "Мне нравится" || rel.TrackCount != 2 ||
		rel.Tracks[0].Title != "T10" || rel.Tracks[1].ID != "11" {
		t.Fatalf("лайки для загрузки = %+v %v", rel, err)
	}
	own, err := c.UserPlaylists(ctx, 5)
	if err != nil || len(own) != 1 || own[0].Link != webBase+"/users/me/playlists/1001" || own[0].Count != 3 {
		t.Fatalf("плейлисты = %+v %v", own, err)
	}
	other, err := c.LikedPlaylists(ctx, 5)
	if err != nil || len(other) != 1 || !strings.HasSuffix(other[0].Link, "/playlists/lk.abcdefabcdefabcdefabcdefabcdefab") {
		t.Fatalf("чужие плейлисты = %+v %v", other, err)
	}
	if err := c.LikeTracks(ctx, 5, []string{"1", "2"}, true); err != nil {
		t.Fatal(err)
	}
	if err := c.DislikeTracks(ctx, 5, []string{"3"}, false); err != nil {
		t.Fatal(err)
	}

	ids := make([]string, 450)
	for i := range ids {
		ids[i] = strconv.Itoa(i + 1)
	}
	list, err := c.Tracks(ctx, ids)
	if err != nil || len(list) != 450 || list[0].ID != "1" || list[449].ID != "450" || list[200].ID != "201" {
		t.Fatalf("треки: %d %v", len(list), err)
	}
	if list[0].Duration != 181000 || list[0].AlbumID != "9" {
		t.Errorf("трек = %+v", list[0])
	}
	if err := c.ReportPlay(ctx, 5, Play{Track: list[0], From: "x", Played: 12.5}); err != nil {
		t.Fatal(err)
	}
	want := "/users/5/likes/tracks/add-multiple?1,2 /users/5/dislikes/tracks/remove?3 /play-audio?1"
	if got := strings.Join(posted, " "); got != want {
		t.Errorf("запросы = %s", got)
	}
}

func TestWave(t *testing.T) {
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Content-Type") != "application/json" || r.Header.Get("Authorization") != "OAuth t" {
			http.Error(w, "bad headers", http.StatusBadRequest)
			return
		}
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		bodies = append(bodies, body)
		switch r.URL.Path {
		case "/rotor/session/new":
			w.Write([]byte(`{"result":{"radioSessionId":"S1","batchId":"B1","sequence":[
				{"type":"track","liked":true,"track":{"id":"1","title":"A","albums":[{"id":7}]}},
				{"type":"ad","track":{"id":"2"}},
				{"type":"track","track":{"id":"3","title":"C","available":false}},
				{"type":"track","track":{"id":"4","title":"D"}}]}}`))
		case "/rotor/session/S1/tracks":
			w.Write([]byte(`{"result":{"batchId":"B2","sequence":[{"type":"track","track":{"id":"5","title":"E"}}]}}`))
		case "/rotor/session/S2/tracks":
			w.Write([]byte(`{"result":{"unknownSession":true}}`))
		case "/rotor/session/S1/feedback":
			w.Write([]byte(`{"result":{}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c := New("t")
	c.base = srv.URL
	ctx := context.Background()

	b, err := c.WaveStart(ctx, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if b.Session != "S1" || b.Batch != "B1" || len(b.Tracks) != 2 || b.Tracks[0].ID != "1" || b.Tracks[1].ID != "4" || !b.Liked["1"] {
		t.Fatalf("первая партия = %+v", b)
	}
	if seeds := bodies[0]["seeds"].([]any); len(seeds) != 1 || seeds[0] != WaveSeed || bodies[0]["includeTracksInResponse"] != true {
		t.Errorf("тело session/new = %v", bodies[0])
	}

	next, err := c.WaveNext(ctx, "S1", b.Tracks)
	if err != nil || next.Session != "S1" || next.Batch != "B2" || len(next.Tracks) != 1 {
		t.Fatalf("следующая партия = %+v %v", next, err)
	}
	if q := bodies[1]["queue"].([]any); len(q) != 2 || q[0] != "1:7" || q[1] != "4" {
		t.Errorf("queue = %v", q)
	}
	if _, err := c.WaveNext(ctx, "S2", nil); !errors.Is(err, ErrWaveEnded) {
		t.Errorf("протухшая сессия: %v", err)
	}

	if err := c.WaveFeedback(ctx, "S1", "B1", WaveSkip, "4", 31.5); err != nil {
		t.Fatal(err)
	}
	fb := bodies[len(bodies)-1]
	ev := fb["event"].(map[string]any)
	if fb["batchId"] != "B1" || ev["type"] != "skip" || ev["trackId"] != "4" || ev["totalPlayedSeconds"] != 31.5 || ev["timestamp"] == "" {
		t.Errorf("отзыв = %v", fb)
	}
}

func TestUploadedTrackTitle(t *testing.T) {
	var tr apiTrack
	if err := json.Unmarshal([]byte(`{"id":"40279b37-a47c-4877-9e89-46e9fd397e3d","title":"Istasha The Scrub - Leviathan.MP3","trackSource":"UGC","artists":[],"albums":[]}`), &tr); err != nil {
		t.Fatal(err)
	}
	got := tr.shape(nil)
	if got.ID != "40279b37-a47c-4877-9e89-46e9fd397e3d" || got.Title != "Istasha The Scrub - Leviathan" {
		t.Errorf("загруженный трек = %+v", got)
	}
	var catalog apiTrack
	_ = json.Unmarshal([]byte(`{"id":"5","title":"Song.mp3"}`), &catalog)
	if catalog.shape(nil).Title != "Song.mp3" {
		t.Error("у трека из каталога название не трогаем")
	}
}

func TestArtistPage(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/artists/1/brief-info":
			w.Write([]byte(`{"result":{"artist":{"name":"Кино","cover":{"uri":"x/%%"}}}}`))
		case "/artists/1/direct-albums":
			w.Write([]byte(`{"result":{"albums":[{"id":10,"title":"Группа крови","year":1988,"trackCount":11}],"pager":{"total":1}}}`))
		case "/artists/1/tracks":
			if r.URL.Query().Get("page-size") == "" {
				http.Error(w, "no page size", http.StatusBadRequest)
				return
			}
			w.Write([]byte(`{"result":{"tracks":[{"id":"7","title":"Кукушка","albums":[{"id":11}]},{"id":"8","title":"Пачка сигарет"}],"pager":{"total":2}}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c := New("t")
	c.base = srv.URL
	r, err := c.ArtistPage(context.Background(), "1")
	if err != nil {
		t.Fatal(err)
	}
	if r.Title != "Кино" || len(r.Tracks) != 2 || r.Tracks[0].AlbumID != "11" || len(r.Albums) != 1 || r.Albums[0].ID != "10" {
		t.Errorf("страница исполнителя = %+v", r)
	}
}

func TestTrackArtistRefs(t *testing.T) {
	var tr apiTrack
	raw := `{"id":"1","title":"Т","artists":[{"id":3,"name":"Кино"},{"id":"171","name":"Various","various":true},{"id":4,"name":" Аквариум "},{"name":"Без ID"}],"albums":[{"id":9,"title":"А"}]}`
	if err := json.Unmarshal([]byte(raw), &tr); err != nil {
		t.Fatal(err)
	}
	got := tr.shape(nil)
	want := []ArtistRef{{ID: "3", Name: "Кино"}, {ID: "4", Name: "Аквариум"}}
	if !slices.Equal(got.ArtistRefs, want) {
		t.Errorf("исполнители = %+v", got.ArtistRefs)
	}
	if got.AlbumID != "9" {
		t.Errorf("альбом = %q", got.AlbumID)
	}
}
