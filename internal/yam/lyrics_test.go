package yam

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"sync/atomic"
	"testing"
)

func TestParseLRC(t *testing.T) {
	body := "[ar:Маяк]\r\n[00:12.34] Город в огнях\n[00:05.5]Первая\n\n[01:02.003][00:20.00] Припев\n[00:30.00]\n[00:40.00] Конец\n[00:45.00]\n"
	want := []LyricLine{
		{5500, "Первая"},
		{12340, "Город в огнях"},
		{20000, "Припев"},
		{30000, ""},
		{40000, "Конец"},
		{45000, ""},
		{62003, "Припев"},
	}
	if got := ParseLRC(body); !reflect.DeepEqual(got, want) {
		t.Errorf("ParseLRC = %v, want %v", got, want)
	}
	if got := ParseLRC("просто текст\nбез меток"); len(got) != 0 {
		t.Errorf("текст без меток = %v", got)
	}
}

func TestLyricsKind(t *testing.T) {
	var tr apiTrack
	json.Unmarshal([]byte(`{"id":"1","lyricsInfo":{"hasAvailableSyncLyrics":false,"hasAvailableTextLyrics":true}}`), &tr)
	if k := tr.shape(nil).Lyrics; k != LyricsText {
		t.Errorf("kind = %q", k)
	}
	json.Unmarshal([]byte(`{"id":"1"}`), &tr)
	tr.Lyrics = nil
	if k := tr.shape(nil).Lyrics; k != LyricsUnknown {
		t.Errorf("без lyricsInfo = %q", k)
	}
	json.Unmarshal([]byte(`{"id":"1","lyricsInfo":{}}`), &tr)
	if k := tr.shape(nil).Lyrics; k != LyricsNone {
		t.Errorf("пустой lyricsInfo = %q", k)
	}
}

func TestLyrics(t *testing.T) {
	var badSign, calls atomic.Int32
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		q := r.URL.Query()
		switch r.URL.Path {
		case "/tracks/1/lyrics", "/tracks/2/lyrics", "/tracks/3/lyrics":
			id := r.URL.Path[len("/tracks/") : len(r.URL.Path)-len("/lyrics")]
			ts, _ := strconv.ParseInt(q.Get("timeStamp"), 10, 64)
			if q.Get("sign") != lyricsSign(id, ts) || r.Header.Get("Authorization") != "OAuth t" {
				badSign.Add(1)
			}
			if id == "3" || (id == "2" && q.Get("format") == "LRC") {
				w.WriteHeader(http.StatusNotFound)
				w.Write([]byte(`{"error":{"name":"not-found"}}`))
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"result": map[string]any{
				"downloadUrl": srv.URL + "/file/" + id + "." + q.Get("format"), "writers": []string{"Автор"},
			}})
		case "/file/1.LRC":
			if r.Header.Get("Authorization") != "" {
				badSign.Add(1)
			}
			w.Write([]byte("[00:01.00] Раз\n[00:02.50] Два\n"))
		case "/file/2.TEXT":
			w.Write([]byte("Строка один\r\n\r\nСтрока два\n"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c := New("t")
	c.base = srv.URL
	ctx := context.Background()

	l, err := c.Lyrics(ctx, "1", LyricsSync)
	if err != nil || !l.Synced || !reflect.DeepEqual(l.Lines, []LyricLine{{1000, "Раз"}, {2500, "Два"}}) || !reflect.DeepEqual(l.Writers, []string{"Автор"}) {
		t.Errorf("синхронный = %+v, %v", l, err)
	}
	l, err = c.Lyrics(ctx, "2", LyricsUnknown)
	if err != nil || l.Synced || !reflect.DeepEqual(l.Lines, []LyricLine{{-1, "Строка один"}, {-1, ""}, {-1, "Строка два"}}) {
		t.Errorf("обычный = %+v, %v", l, err)
	}
	l, err = c.Lyrics(ctx, "3", LyricsUnknown)
	if err != nil || len(l.Lines) != 0 {
		t.Errorf("нет текста = %+v, %v", l, err)
	}
	before := calls.Load()
	if l, err = c.Lyrics(ctx, "3", LyricsNone); err != nil || len(l.Lines) != 0 || calls.Load() != before {
		t.Errorf("без текста не должно быть запросов: %+v, %v", l, err)
	}
	if n := badSign.Load(); n != 0 {
		t.Errorf("неверных подписей или заголовков: %d", n)
	}
}
