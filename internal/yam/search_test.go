package yam

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSearch(t *testing.T) {
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.URL.Query().Get("type")+":"+r.URL.Query().Get("page")+":"+r.URL.Query().Get("text"))
		if r.URL.Query().Get("type") == "playlist" {
			w.Write([]byte(`{"result":{"type":"playlist","page":1,"perPage":10,"text":"кино","playlists":{"total":12,"perPage":10,"results":[
				{"uid":5,"kind":7,"playlistUuid":"lk.x","title":"Без логина","owner":{"uid":5,"name":"Кто-то"},"trackCount":3,"cover":{"type":"mosaic","itemsUri":["a/%%"]}}]}}}`))
			return
		}
		w.Write([]byte(`{"result":{"misspellCorrected":false,"misspellResult":"metallica","text":"metalika",
			"best":{"type":"artist","result":{"id":3121,"name":"Metallica","cover":{"uri":"avatars/%%"},"genres":["thrashmetal"],"counts":{"tracks":347}}},
			"tracks":{"total":25,"perPage":20,"results":[
				{"id":1,"title":"One","durationMs":446000,"contentWarning":"explicit","artists":[{"name":"Metallica"}],"albums":[{"id":4766,"title":"Metallica","year":1991,"coverUri":"c/%%"}]},
				{"id":2,"title":"Эпизод","artists":[],"albums":[{"id":9,"title":"Подкаст","metaType":"podcast"}]}]},
			"albums":{"total":1,"perPage":10,"results":[{"id":4766,"title":"Metallica","version":"Remastered","year":1991,"trackCount":12,"type":"","artists":[{"name":"Metallica"}]}]},
			"artists":{"total":1,"perPage":10,"results":[{"id":3121,"name":"Metallica","counts":{"tracks":347}}]},
			"playlists":{"total":1,"perPage":4,"results":[{"uid":457553308,"kind":41075,"title":"Лучшее","owner":{"uid":457553308,"login":"yamusic-bestsongs","name":"Яндекс Музыка"},"trackCount":20,"cover":{"uri":"p/%%"}}]},
			"podcasts":{"total":3,"perPage":10,"results":[{"id":1}]}}}`))
	}))
	defer srv.Close()
	c := New("t")
	c.base = srv.URL

	r, err := c.Search(context.Background(), "metalika", "", 0)
	if err != nil {
		t.Fatal(err)
	}
	if r.Corrected != "metallica" {
		t.Errorf("исправление = %q", r.Corrected)
	}
	if r.Best == nil || r.Best.Kind != KindArtist || r.Best.Link != "https://music.yandex.ru/artist/3121" || r.Best.Count != 347 {
		t.Errorf("best = %+v", r.Best)
	}
	if len(r.Sections) != 4 {
		t.Errorf("секции = %v", r.Sections)
	}
	tracks := r.Sections[KindTrack]
	if tracks.Total != 25 || len(tracks.Hits) != 1 {
		t.Fatalf("треки = %+v", tracks)
	}
	if h := tracks.Hits[0]; h.Link != "https://music.yandex.ru/album/4766/track/1" || h.Duration != 446 || !h.Explicit || h.Album != "Metallica" || h.Year != 1991 {
		t.Errorf("трек = %+v", h)
	}
	if h := r.Sections[KindAlbum].Hits[0]; h.Title != "Metallica (Remastered)" || h.Type != "album" || h.Count != 12 || h.Link != "https://music.yandex.ru/album/4766" {
		t.Errorf("альбом = %+v", h)
	}
	if h := r.Sections[KindPlaylist].Hits[0]; h.Link != "https://music.yandex.ru/users/yamusic-bestsongs/playlists/41075" || h.Artist != "Яндекс Музыка" {
		t.Errorf("плейлист = %+v", h)
	}
	for _, h := range []Hit{*r.Best, r.Sections[KindTrack].Hits[0], r.Sections[KindAlbum].Hits[0], r.Sections[KindArtist].Hits[0], r.Sections[KindPlaylist].Hits[0]} {
		if _, err := ParseLink(h.Link); err != nil {
			t.Errorf("ссылка %q не распознаётся: %v", h.Link, err)
		}
	}

	p, err := c.Search(context.Background(), "кино", KindPlaylist, 1)
	if err != nil {
		t.Fatal(err)
	}
	if h := p.Sections[KindPlaylist].Hits[0]; h.Link != "https://music.yandex.ru/users/5/playlists/7" || h.Cover != "a/%%" {
		t.Errorf("плейлист без логина = %+v", h)
	}
	if got[0] != "all:0:metalika" || got[1] != "playlist:1:кино" {
		t.Errorf("запросы = %v", got)
	}
}
