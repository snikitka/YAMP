package gui

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"yamp/internal/yam"
)

type fakeMusic struct {
	srv   *httptest.Server
	key   []byte
	plain []byte
	enc   []byte

	offline atomic.Bool

	mu       sync.Mutex
	feedback []string
	plays    []string
	likes    []string
	waveCall int
	seeds    []string

	lyricCalls int
}

func newFakeMusic(t *testing.T) *fakeMusic {
	f := &fakeMusic{key: bytes.Repeat([]byte{7}, 16), plain: bytes.Repeat([]byte("audio-frame-"), 4000)}
	block, _ := aes.NewCipher(f.key)
	f.enc = make([]byte, len(f.plain))
	cipher.NewCTR(block, make([]byte, 16)).XORKeyStream(f.enc, f.plain)
	track := func(id string) string {
		return `{"id":"` + id + `","title":"T` + id + `","durationMs":200000,"artists":[{"name":"A"}],"albums":[{"id":9,"title":"Al"}]}`
	}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if f.offline.Load() {
			if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
				conn.Close()
			}
			return
		}
		f.mu.Lock()
		defer f.mu.Unlock()
		r.ParseForm()
		switch r.URL.Path {
		case "/account/status":
			w.Write([]byte(`{"result":{"account":{"uid":5,"login":"me"},"plus":{"hasPlus":true}}}`))
		case "/users/5/likes/tracks":
			w.Write([]byte(`{"result":{"library":{"tracks":[{"id":"20"}]}}}`))
		case "/users/5/dislikes/tracks":
			w.Write([]byte(`{"result":{"library":{"tracks":[]}}}`))
		case "/users/5/likes/tracks/add-multiple", "/users/5/likes/tracks/remove", "/users/5/dislikes/tracks/add-multiple":
			f.likes = append(f.likes, strings.TrimPrefix(r.URL.Path, "/users/5/")+"="+r.PostForm.Get("track-ids"))
			w.Write([]byte(`{"result":{"revision":1}}`))
		case "/rotor/session/new":
			var body struct {
				Seeds []string `json:"seeds"`
				Queue []string `json:"queue"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			f.seeds = append(f.seeds, strings.Join(body.Seeds, ",")+"|"+strings.Join(body.Queue, ","))
			if len(body.Seeds) == 1 && strings.HasPrefix(body.Seeds[0], "playlist:") {
				http.Error(w, "bad seed", http.StatusBadRequest)
				return
			}
			w.Write([]byte(`{"result":{"radioSessionId":"S","batchId":"B1","sequence":[{"type":"track","track":` + track("1") + `},{"type":"track","track":` + track("2") + `}]}}`))
		case "/rotor/session/S/tracks":
			f.waveCall++
			id := []string{"3", "4", "5"}[min(f.waveCall-1, 2)]
			w.Write([]byte(`{"result":{"batchId":"B2","sequence":[{"type":"track","track":` + track(id) + `}]}}`))
		case "/rotor/session/S/feedback":
			var body struct {
				Event struct {
					Type    string `json:"type"`
					TrackID string `json:"trackId"`
				} `json:"event"`
				BatchID string `json:"batchId"`
			}
			json.NewDecoder(r.Body).Decode(&body)
			f.feedback = append(f.feedback, body.Event.Type+":"+body.Event.TrackID+"@"+body.BatchID)
			w.Write([]byte(`{"result":{}}`))
		case "/play-audio":
			f.plays = append(f.plays, r.PostForm.Get("track-id")+"/"+r.PostForm.Get("from"))
			w.Write([]byte(`{"result":"ok"}`))
		case "/albums/9/with-tracks":
			w.Write([]byte(`{"result":{"id":9,"title":"Al","coverUri":"c/%%","artists":[{"id":3,"name":"A"}],"volumes":[[` + track("20") + `]]}}`))
		case "/artists/3/brief-info":
			w.Write([]byte(`{"result":{"artist":{"name":"A"}}}`))
		case "/artists/3/direct-albums":
			w.Write([]byte(`{"result":{"albums":[{"id":9,"title":"Al","coverUri":"c/%%","year":2001}],"pager":{"total":1}}}`))
		case "/artists/3/tracks":
			w.Write([]byte(`{"result":{"tracks":[` + track("20") + `,` + track("21") + `]}}`))
		case "/users/me/playlists/1001":
			w.Write([]byte(`{"result":{"title":"Дорога","trackCount":3,"tracks":[{"track":` + track("20") + `},{"track":` + track("21") + `},{"track":` + track("22") + `}]}}`))
		case "/feed":
			w.Write([]byte(`{"result":{"generatedPlaylists":[{"type":"playlistOfTheDay","ready":true,"data":{"uid":5,"kind":100,"title":"Плейлист дня","owner":{"login":"yamusic-daily"}}},{"type":"missedLikes","ready":false,"data":{"uid":5,"kind":101,"title":"Не готов"}}]}}`))
		case "/music-history":
			played := func(id string) string { return `{"type":"track","data":{"fullModel":` + track(id) + `}}` }
			w.Write([]byte(`{"result":{"historyTabs":[{"date":"2026-11-04","items":[` +
				`{"context":{"type":"album","data":{"fullModel":{"album":{"id":9,"title":"Al","artists":[{"name":"A"}]}}}},"tracks":[` + played("20") + `,` + played("21") + `]},` +
				`{"context":{"type":"wave","data":{}}},` +
				`{"context":{"type":"album","data":{"fullModel":{"album":{"id":9,"title":"Al"}}}}},` +
				`{"context":{"type":"artist","data":{"fullModel":{"artist":{"id":3,"name":"A"}}}}}]},` +
				`{"date":"2026-11-03","items":[{"context":{"type":"wave","data":{}},"tracks":[` + played("21") + `,` + played("22") + `]}]}]}}`))
		case "/landing3/new-releases":
			w.Write([]byte(`{"result":{"newReleases":[11,12]}}`))
		case "/albums":
			ids := strings.Split(r.PostForm.Get("album-ids"), ",")
			var items []string
			for _, id := range ids {
				items = append(items, `{"id":`+id+`,"title":"New `+id+`","artists":[{"name":"B"}],"year":2026}`)
			}
			w.Write([]byte(`{"result":[` + strings.Join(items, ",") + `]}`))
		case "/landing3/new-playlists":
			w.Write([]byte(`{"result":{"newPlaylists":[{"uid":7,"kind":3}]}}`))
		case "/playlists/list":
			if r.PostForm.Get("playlist-ids") != "7:3" {
				http.Error(w, "bad ids", http.StatusBadRequest)
				return
			}
			w.Write([]byte(`{"result":[{"uid":7,"kind":3,"title":"Свежее","trackCount":40,"owner":{"login":"music"}}]}`))
		case "/landing3/chart":
			w.Write([]byte(`{"result":{"title":"Чарт","chart":{"tracks":[{"track":` + track("31") + `,"chart":{"position":1}},{"track":` + track("32") + `,"chart":{"position":2}}]}}}`))
		case "/get-file-info":
			json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"downloadInfo": map[string]any{
				"codec": "flac-mp4", "key": hex.EncodeToString(f.key), "urls": []string{f.srv.URL + "/file/" + r.URL.Query().Get("trackId")},
			}}})
		case "/tracks/20/lyrics":
			f.lyricCalls++
			json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{"downloadUrl": f.srv.URL + "/lyrics/20", "writers": []string{"W"}}})
		case "/lyrics/20":
			w.Write([]byte("[00:01.00] Раз\n[00:03.00] Два\n"))
		default:
			if strings.HasPrefix(r.URL.Path, "/file/") {
				http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(f.enc))
				return
			}
			http.NotFound(w, r)
		}
	}))
	return f
}

func (f *fakeMusic) snapshot() (feedback, plays, likes []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.feedback...), append([]string(nil), f.plays...), append([]string(nil), f.likes...)
}

type eventLog struct {
	ch chan map[string]any
}

func (e *eventLog) wait(t *testing.T, typ string, ok func(map[string]any) bool) map[string]any {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case ev := <-e.ch:
			if ev["type"] == typ && (ok == nil || ok(ev)) {
				return ev
			}
		case <-deadline:
			t.Fatalf("не дождались события %s", typ)
			return nil
		}
	}
}

func playing(id, action string) func(map[string]any) bool {
	return func(ev map[string]any) bool {
		tr, _ := ev["track"].(map[string]any)
		return tr != nil && tr["id"] == id && ev["action"] == action
	}
}

func startPlayerCore(t *testing.T) (*Core, *fakeMusic, *eventLog) {
	dir := t.TempDir()
	for _, v := range []string{"AppData", "HOME", "XDG_CONFIG_HOME"} {
		t.Setenv(v, dir)
	}
	f := newFakeMusic(t)
	t.Cleanup(f.srv.Close)
	old := yam.APIBase
	yam.APIBase = f.srv.URL
	t.Cleanup(func() { yam.APIBase = old })

	log := &eventLog{ch: make(chan map[string]any, 256)}
	c := Start(func(b []byte) {
		var ev map[string]any
		if json.Unmarshal(b, &ev) == nil {
			select {
			case log.ch <- ev:
			default:
			}
		}
	})
	c.app.upd.mu.Lock()
	c.app.upd.checked = true
	c.app.upd.mu.Unlock()
	sess, _, err := yam.Open(context.Background(), "t")
	if err != nil {
		t.Fatal(err)
	}
	c.app.mu.Lock()
	c.app.session, c.app.token = sess, "t"
	c.app.mu.Unlock()
	t.Cleanup(func() {
		c.Close()
		c.Wait()
		time.Sleep(50 * time.Millisecond)
		done := make(chan struct{})
		c.app.player.saves.run(func() { close(done) })
		<-done
	})
	return c, f, log
}

func send(c *Core, cmd map[string]any) {
	b, _ := json.Marshal(cmd)
	c.Send(b)
}

func TestPlayerWave(t *testing.T) {
	c, f, log := startPlayerCore(t)

	send(c, map[string]any{"cmd": "play", "source": "wave"})
	log.wait(t, "player", func(ev map[string]any) bool { return ev["loading"] == true })
	ev := log.wait(t, "player", playing("1", "play"))
	if ev["wave"] != true || ev["quality"] != "lossless" || ev["volume"] != 0.8 {
		t.Fatalf("состояние волны = %v", ev)
	}
	next, _ := ev["next"].(map[string]any)
	if next == nil || next["id"] != "2" || ev["nextUrl"] == "" {
		t.Errorf("следующий = %v", ev["next"])
	}
	format := log.wait(t, "playerFormat", nil)
	if format["track"] != "1" || format["format"] != "FLAC" {
		t.Errorf("формат = %v", format)
	}

	resp, err := http.Get(ev["url"].(string))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !bytes.Equal(body, f.plain) {
		t.Fatalf("поток не расшифрован: %d байт", len(body))
	}

	send(c, map[string]any{"cmd": "playerStarted", "track": "1"})
	send(c, map[string]any{"cmd": "playerEnded", "track": "1", "position": 200})
	log.wait(t, "player", playing("2", "play"))
	log.wait(t, "queue", func(ev map[string]any) bool { return len(ev["tracks"].([]any)) == 3 })

	send(c, map[string]any{"cmd": "playerEnded", "track": "1", "position": 200})
	send(c, map[string]any{"cmd": "dislike", "track": "2", "on": true, "position": 12})
	mark := log.wait(t, "mark", nil)
	if mark["track"] != "2" || mark["disliked"] != true {
		t.Errorf("дизлайк = %v", mark)
	}
	log.wait(t, "player", playing("3", "play"))

	send(c, map[string]any{"cmd": "playerRepeat", "repeat": "all"})
	rep := log.wait(t, "player", func(ev map[string]any) bool { return ev["action"] == nil })
	if rep["repeat"] != "off" {
		t.Errorf("в волне повтор всего = %v", rep["repeat"])
	}
	send(c, map[string]any{"cmd": "playerEnded", "track": "3", "position": 200})
	log.wait(t, "player", playing("4", "play"))

	deadline := time.Now().Add(3 * time.Second)
	for {
		feedback, plays, likes := f.snapshot()
		want := "radioStarted:@B1 trackStarted:1@B1 trackFinished:1@B1 skip:2@B1 trackFinished:3@B2"
		if strings.Join(feedback, " ") == want && len(plays) == 3 && len(likes) == 1 {
			if plays[0] != "1/"+yam.WaveFrom || likes[0] != "dislikes/tracks/add-multiple=2" {
				t.Errorf("история %v, отметки %v", plays, likes)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("отзывы %v, история %v, отметки %v", feedback, plays, likes)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestPlayerPlaylist(t *testing.T) {
	c, f, log := startPlayerCore(t)
	link := "https://music.yandex.ru/users/me/playlists/1001"

	send(c, map[string]any{"cmd": "open", "source": link})
	list := log.wait(t, "tracks", nil)
	items := list["tracks"].([]any)
	if len(items) != 3 || items[0].(map[string]any)["liked"] != true || items[1].(map[string]any)["liked"] != nil {
		t.Fatalf("плейлист = %v", list)
	}

	send(c, map[string]any{"cmd": "play", "source": link, "track": "21"})
	ev := log.wait(t, "player", playing("21", "play"))
	if src := ev["source"].(map[string]any); src["title"] != "Дорога" || ev["wave"] != false {
		t.Errorf("источник = %v", ev["source"])
	}

	send(c, map[string]any{"cmd": "playerRepeat", "repeat": "one"})
	log.wait(t, "player", func(ev map[string]any) bool { return ev["repeat"] == "one" })
	send(c, map[string]any{"cmd": "playerEnded", "track": "21", "position": 200})
	log.wait(t, "player", playing("21", "play"))
	send(c, map[string]any{"cmd": "playerNext", "track": "21", "position": 5})
	log.wait(t, "player", playing("22", "play"))
	send(c, map[string]any{"cmd": "playerPrev", "track": "22", "position": 10})
	log.wait(t, "player", playing("22", "play"))
	send(c, map[string]any{"cmd": "playerPrev", "track": "22", "position": 1})
	log.wait(t, "player", playing("21", "play"))

	send(c, map[string]any{"cmd": "like", "track": "21", "on": true})
	mark := log.wait(t, "mark", nil)
	if mark["liked"] != true || mark["likedCount"] != 2.0 {
		t.Errorf("лайк = %v", mark)
	}

	send(c, map[string]any{"cmd": "playerQuality", "quality": "low"})
	ev = log.wait(t, "player", playing("21", "resume"))
	if ev["quality"] != "low" || !strings.HasSuffix(ev["url"].(string), "/21?q=low") {
		t.Errorf("качество = %v %v", ev["quality"], ev["url"])
	}
	send(c, map[string]any{"cmd": "playerVolume", "volume": 1.7})
	send(c, map[string]any{"cmd": "playerState"})
	if ev := log.wait(t, "player", nil); ev["volume"] != 1.0 {
		t.Errorf("громкость = %v", ev["volume"])
	}
	cfg := loadConfig()
	if cfg.PlayQuality != "low" || cfg.volume() != 1 || cfg.Repeat != "one" {
		t.Errorf("настройки не сохранились: %+v", cfg)
	}

	send(c, map[string]any{"cmd": "logout"})
	log.wait(t, "player", func(ev map[string]any) bool { return ev["action"] == "stop" && ev["track"] == nil })

	deadline := time.Now().Add(3 * time.Second)
	for {
		_, plays, likes := f.snapshot()
		if len(likes) == 1 && len(plays) == 3 {
			if likes[0] != "likes/tracks/add-multiple=21" {
				t.Errorf("отметки %v", likes)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("история %v, отметки %v", plays, likes)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestPlayTrackLinks(t *testing.T) {
	p := newPlayerState(config{})
	pt := p.shape(yam.Track{ID: "5", AlbumID: "9", Artists: "Кино", ArtistRefs: []yam.ArtistRef{{ID: "3", Name: "Кино"}}}, "200x200")
	if pt.AlbumSource != "https://music.yandex.ru/album/9" || pt.Link != "https://music.yandex.ru/album/9/track/5" {
		t.Errorf("ссылки = %q %q", pt.AlbumSource, pt.Link)
	}
	if len(pt.Artists) != 1 || pt.Artists[0] != (playArtist{Name: "Кино", Source: "https://music.yandex.ru/artist/3"}) {
		t.Errorf("исполнители = %+v", pt.Artists)
	}
	if bare := p.shape(yam.Track{ID: "6"}, ""); bare.AlbumSource != "" || bare.Artists != nil {
		t.Errorf("без альбома и исполнителей = %+v", bare)
	}
}

func TestPlayerOpenAlbumsOnlyForArtist(t *testing.T) {
	c, _, log := startPlayerCore(t)
	open := func(source string) map[string]any {
		send(c, map[string]any{"cmd": "open", "source": source})
		return log.wait(t, "tracks", func(ev map[string]any) bool { return ev["source"] == source })
	}
	album := open("https://music.yandex.ru/album/9")
	if _, ok := album["albums"]; ok {
		t.Errorf("у альбома не должно быть списка альбомов: %v", album["albums"])
	}
	info := album["info"].(map[string]any)
	if a := info["artists"].([]any)[0].(map[string]any); a["source"] != "https://music.yandex.ru/artist/3" {
		t.Errorf("исполнитель альбома = %v", a)
	}
	artist := open("https://music.yandex.ru/artist/3")
	albums, _ := artist["albums"].([]any)
	if len(albums) != 1 || albums[0].(map[string]any)["cover"] != "https://c/400x400" {
		t.Errorf("альбомы исполнителя = %v", artist["albums"])
	}
	top := open("https://music.yandex.ru/artist/3/tracks")
	if _, ok := top["albums"]; ok || len(top["tracks"].([]any)) != 2 {
		t.Errorf("популярные треки = %v", top)
	}
}

func TestHome(t *testing.T) {
	c, _, log := startPlayerCore(t)

	send(c, map[string]any{"cmd": "home"})
	ev := log.wait(t, "home", nil)
	if ev["error"] != nil {
		t.Fatalf("главная с ошибкой: %v", ev["error"])
	}
	titles := func(key string) []string {
		var out []string
		list, _ := ev[key].([]any)
		for _, it := range list {
			m, _ := it.(map[string]any)
			out = append(out, fmt.Sprint(m["title"], "|", m["link"]))
		}
		return out
	}
	check := func(key string, want ...string) {
		t.Helper()
		if got := titles(key); strings.Join(got, ";") != strings.Join(want, ";") {
			t.Errorf("%s = %v, ждали %v", key, got, want)
		}
	}
	check("personal", "Плейлист дня|https://music.yandex.ru/users/yamusic-daily/playlists/100")
	check("history", "Al|https://music.yandex.ru/album/9", "A|https://music.yandex.ru/artist/3")
	check("releases", "New 11|https://music.yandex.ru/album/11", "New 12|https://music.yandex.ru/album/12")
	check("playlists", "Свежее|https://music.yandex.ru/users/music/playlists/3")
	check("chart", "T31|https://music.yandex.ru/album/9/track/31", "T32|https://music.yandex.ru/album/9/track/32")

	send(c, map[string]any{"cmd": "play", "source": "chart", "track": "32"})
	played := log.wait(t, "player", playing("32", "play"))
	src, _ := played["source"].(map[string]any)
	if src["kind"] != "chart" || src["title"] != "Чарт" {
		t.Errorf("источник = %v", played["source"])
	}
}

func TestPlayerHistory(t *testing.T) {
	c, _, log := startPlayerCore(t)

	send(c, map[string]any{"cmd": "open", "source": "history"})
	ev := log.wait(t, "tracks", func(m map[string]any) bool { return m["source"] == "history" })
	if ev["error"] != nil {
		t.Fatalf("история с ошибкой: %v", ev["error"])
	}
	var ids []string
	for _, it := range ev["tracks"].([]any) {
		ids = append(ids, fmt.Sprint(it.(map[string]any)["id"]))
	}
	if got := strings.Join(ids, ","); got != "20,21,21,22" {
		t.Errorf("треки истории = %s", got)
	}
	days, _ := json.Marshal(ev["days"])
	if string(days) != `[{"count":2,"date":"2026-11-04"},{"count":2,"date":"2026-11-03"}]` {
		t.Errorf("дни = %s", days)
	}
	if info, _ := ev["info"].(map[string]any); info["kind"] != "history" || info["title"] != "История" {
		t.Errorf("источник = %v", ev["info"])
	}

	send(c, map[string]any{"cmd": "play", "source": "history", "track": "21", "index": 2})
	played := log.wait(t, "player", playing("21", "play"))
	if played["pos"] != float64(2) {
		t.Errorf("начали с позиции %v, ждали 2", played["pos"])
	}
}

func TestPlayerWaitsForNetwork(t *testing.T) {
	c, f, log := startPlayerCore(t)
	link := "https://music.yandex.ru/users/me/playlists/1001"

	send(c, map[string]any{"cmd": "play", "source": link, "track": "21"})
	log.wait(t, "player", playing("21", "play"))
	send(c, map[string]any{"cmd": "playerStarted", "track": "21"})

	send(c, map[string]any{"cmd": "playerError", "track": "21", "message": "tcp: timeout", "position": 42.5})
	ev := log.wait(t, "player", playing("21", "retry"))
	if ev["start"] != 42.5 {
		t.Errorf("продолжение с %v", ev["start"])
	}

	f.offline.Store(true)
	send(c, map[string]any{"cmd": "playerError", "track": "21", "message": "tcp: timeout", "position": 0})
	ev = log.wait(t, "player", func(ev map[string]any) bool { return ev["offline"] == true })
	if tr := ev["track"].(map[string]any); tr["id"] != "21" || ev["loading"] != true {
		t.Errorf("ожидание сети = %v", ev)
	}
	send(c, map[string]any{"cmd": "playerError", "track": "21", "message": "again", "position": 0})
	f.offline.Store(false)
	ev = log.wait(t, "player", playing("21", "retry"))
	if ev["offline"] != nil || ev["start"] != nil {
		t.Errorf("после сети = %v", ev)
	}

	f.offline.Store(true)
	send(c, map[string]any{"cmd": "playerError", "track": "21", "message": "tcp: timeout", "position": 3})
	log.wait(t, "player", func(ev map[string]any) bool { return ev["offline"] == true })
	send(c, map[string]any{"cmd": "playerNext", "track": "21", "position": 3})
	ev = log.wait(t, "player", playing("22", "play"))
	if ev["offline"] != nil {
		t.Errorf("переключение не сбросило ожидание: %v", ev)
	}
	f.offline.Store(false)
}

func (f *fakeMusic) waveSeeds() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.seeds...)
}

func TestPlayerWaveFromSource(t *testing.T) {
	c, f, log := startPlayerCore(t)

	send(c, map[string]any{"cmd": "wave", "source": "https://music.yandex.ru/album/9", "track": "20", "title": "Al"})
	ev := log.wait(t, "player", playing("1", "play"))
	if src := ev["source"].(map[string]any); src["kind"] != "wave" || src["title"] != "Моя волна: Al" || ev["wave"] != true {
		t.Errorf("волна по альбому = %v", ev["source"])
	}

	send(c, map[string]any{"cmd": "wave", "source": "https://music.yandex.ru/users/me/playlists/1001", "track": "21"})
	log.wait(t, "player", playing("1", "play"))

	send(c, map[string]any{"cmd": "wave", "track": "22", "title": "T22"})
	log.wait(t, "player", playing("1", "play"))

	link := "https://music.yandex.ru/users/me/playlists/1001"
	send(c, map[string]any{"cmd": "play", "source": link, "track": "22"})
	log.wait(t, "player", playing("22", "play"))
	send(c, map[string]any{"cmd": "playerEnded", "track": "22", "position": 200})
	ev = log.wait(t, "player", playing("1", "play"))
	if ev["wave"] != true {
		t.Errorf("после плейлиста не включилась волна: %v", ev)
	}

	want := []string{"album:9|", "playlist:me_1001|", "track:21|", "track:22|", "track:22|20:9,21:9,22:9"}
	if got := f.waveSeeds(); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("сиды = %v", got)
	}
}

func TestPlayerResume(t *testing.T) {
	c, _, log := startPlayerCore(t)
	link := "https://music.yandex.ru/users/me/playlists/1001"

	send(c, map[string]any{"cmd": "play", "source": link, "track": "21"})
	log.wait(t, "player", playing("21", "play"))
	send(c, map[string]any{"cmd": "playerPosition", "track": "21", "position": 33.5, "on": true})

	deadline := time.Now().Add(3 * time.Second)
	for {
		b, _ := os.ReadFile(resumePath())
		var s savedPlayer
		if json.Unmarshal(b, &s) == nil && s.Position == 33.5 {
			if len(s.Tracks) != 3 || s.Pos != 1 || s.Source == nil || s.Source.Title != "Дорога" {
				t.Fatalf("сохранено %+v", s)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("место не сохранилось: %s", b)
		}
		time.Sleep(20 * time.Millisecond)
	}

	p := c.app.player
	p.mu.Lock()
	p.queue.Clear()
	p.source, p.restored = nil, false
	p.mu.Unlock()
	c.app.restorePlayer()
	ev := log.wait(t, "player", playing("21", "restore"))
	if ev["start"] != 33.5 || ev["source"].(map[string]any)["title"] != "Дорога" || ev["url"] == "" {
		t.Errorf("восстановление = %v", ev)
	}
	if next, _ := ev["next"].(map[string]any); next == nil || next["id"] != "22" {
		t.Errorf("следующий после восстановления = %v", ev["next"])
	}

	send(c, map[string]any{"cmd": "logout"})
	log.wait(t, "player", func(ev map[string]any) bool { return ev["action"] == "stop" })
	deadline = time.Now().Add(3 * time.Second)
	for {
		if _, err := os.Stat(resumePath()); os.IsNotExist(err) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("после выхода место не забыто")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestPlayerResumeWave(t *testing.T) {
	c, f, log := startPlayerCore(t)
	tracks := []yam.Track{{ID: "7", Title: "T7", Available: true}, {ID: "8", Title: "T8", Available: true}}
	if err := writeResume(savedPlayer{Tracks: tracks, Pos: 1, Position: 7, Wave: true, Seeds: []string{"track:9"}}); err != nil {
		t.Fatal(err)
	}
	c.app.restorePlayer()
	ev := log.wait(t, "player", playing("8", "restore"))
	if ev["wave"] != true {
		t.Errorf("волна не восстановилась: %v", ev)
	}
	send(c, map[string]any{"cmd": "playerEnded", "track": "8", "position": 200})
	log.wait(t, "player", playing("1", "play"))
	if got := f.waveSeeds(); len(got) != 1 || got[0] != "track:9|7,8" {
		t.Errorf("волна после восстановления = %v", got)
	}
}

func TestPlayerAutoQuality(t *testing.T) {
	c, _, log := startPlayerCore(t)
	link := "https://music.yandex.ru/users/me/playlists/1001"

	send(c, map[string]any{"cmd": "play", "source": link, "track": "21"})
	ev := log.wait(t, "player", playing("21", "play"))
	if ev["quality"] != "lossless" || ev["autoQuality"] != true {
		t.Fatalf("по умолчанию авто и FLAC: %v %v", ev["quality"], ev["autoQuality"])
	}

	send(c, map[string]any{"cmd": "network", "metered": true})
	st := log.wait(t, "state", func(m map[string]any) bool { return m["metered"] == true })
	if st["playQuality"] != "mp3" || st["playMobile"] != "mp3" || st["playWifi"] != "lossless" || st["playAuto"] != true {
		t.Errorf("состояние в мобильной сети = %v", st)
	}
	ev = log.wait(t, "player", func(m map[string]any) bool { return m["quality"] == "mp3" })
	if ev["action"] != nil || !strings.HasSuffix(ev["url"].(string), "/21?q=mp3") {
		t.Errorf("смена сети не должна перезапускать трек: %v %v", ev["action"], ev["url"])
	}

	send(c, map[string]any{"cmd": "playQuality", "mobile": "low"})
	log.wait(t, "player", playing("21", "resume"))

	send(c, map[string]any{"cmd": "playQuality", "auto": false, "quality": "lossless"})
	ev = log.wait(t, "player", playing("21", "resume"))
	if ev["quality"] != "lossless" || ev["autoQuality"] != nil {
		t.Errorf("вручную = %v %v", ev["quality"], ev["autoQuality"])
	}
	cfg := loadConfig()
	if cfg.autoQuality() || cfg.mobileQuality() != yam.Low || cfg.PlayQuality != "lossless" {
		t.Errorf("настройки не сохранились: %+v", cfg)
	}

	send(c, map[string]any{"cmd": "playerQuality", "quality": "auto"})
	ev = log.wait(t, "player", playing("21", "resume"))
	if ev["quality"] != "low" || ev["autoQuality"] != true {
		t.Errorf("снова авто = %v %v", ev["quality"], ev["autoQuality"])
	}
}

func TestPlayerWaveKeepsCurrentTrack(t *testing.T) {
	c, f, log := startPlayerCore(t)
	link := "https://music.yandex.ru/users/me/playlists/1001"

	send(c, map[string]any{"cmd": "play", "source": link, "track": "21"})
	log.wait(t, "player", playing("21", "play"))

	send(c, map[string]any{"cmd": "wave", "track": "21", "title": "T21"})
	q := log.wait(t, "queue", func(ev map[string]any) bool {
		src, _ := ev["source"].(map[string]any)
		return src != nil && src["kind"] == "wave" && len(ev["tracks"].([]any)) == 3
	})
	var ids []string
	for _, it := range q["tracks"].([]any) {
		ids = append(ids, it.(map[string]any)["id"].(string))
	}
	if strings.Join(ids, ",") != "21,1,2" || q["pos"] != 0.0 {
		t.Errorf("очередь волны = %v на %v", ids, q["pos"])
	}
	if got := f.waveSeeds(); len(got) != 1 || got[0] != "track:21|21:9" {
		t.Errorf("сиды = %v", got)
	}

	send(c, map[string]any{"cmd": "playerEnded", "track": "21", "position": 200})
	ev := log.wait(t, "player", playing("1", "play"))
	if ev["wave"] != true {
		t.Errorf("после текущего трека не волна: %v", ev)
	}
}

func TestPlayerLyrics(t *testing.T) {
	c, f, log := startPlayerCore(t)
	send(c, map[string]any{"cmd": "lyrics", "track": "20"})
	ev := log.wait(t, "lyrics", nil)
	lines, _ := ev["lines"].([]any)
	if ev["track"] != "20" || ev["synced"] != true || len(lines) != 2 || ev["error"] != nil {
		t.Fatalf("текст = %v", ev)
	}
	if first, _ := lines[0].(map[string]any); first["ms"] != 1000.0 || first["text"] != "Раз" {
		t.Errorf("первая строка = %v", lines[0])
	}
	send(c, map[string]any{"cmd": "lyrics", "track": "20"})
	log.wait(t, "lyrics", nil)
	send(c, map[string]any{"cmd": "lyrics", "track": "21"})
	ev = log.wait(t, "lyrics", func(ev map[string]any) bool { return ev["track"] == "21" })
	if lines, _ := ev["lines"].([]any); len(lines) != 0 || ev["error"] != nil {
		t.Errorf("у трека без текста = %v", ev)
	}
	f.mu.Lock()
	calls := f.lyricCalls
	f.mu.Unlock()
	if calls != 1 {
		t.Errorf("запросов текста = %d, второй раз должен браться из памяти", calls)
	}
}
