package yam

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHistoryDays(t *testing.T) {
	full := func(id string) string {
		return `{"type":"track","data":{"itemId":{"trackId":"` + id + `"},"fullModel":{"id":"` + id + `","title":"T` + id +
			`","durationMs":1000,"artists":[{"id":1,"name":"A"}],"albums":[{"id":9,"title":"Al"}]}}}`
	}
	bare := func(id string) string { return `{"type":"track","data":{"itemId":{"trackId":"` + id + `","albumId":"9"}}}` }
	var models, asked string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/music-history":
			models = r.URL.Query().Get("fullModelsCount")
			w.Write([]byte(`{"result":{"historyTabs":[` +
				`{"date":"2026-11-04","items":[` +
				`{"context":{"type":"wave","data":{}},"tracks":[` + full("1") + `]},` +
				`{"context":{"type":"playlist","data":{"itemId":{"uid":5,"kind":3}}},"tracks":[` + full("2") + `,` + full("1") + `,` + bare("3") + `,{"type":"video","data":{"itemId":{"trackId":"7"}}}]}]},` +
				`{"date":"2026-11-03","items":[{"context":{"type":"album"},"tracks":[` + bare("1") + `,` + bare("99") + `]}]},` +
				`{"date":"2026-11-02","items":[{"context":{"type":"album"},"tracks":[` + bare("99") + `]}]},` +
				`{"date":"2026-11-01","items":[]}]}}`))
		case "/tracks":
			r.ParseForm()
			asked = r.PostForm.Get("track-ids")
			var items []string
			for _, id := range strings.Split(asked, ",") {
				if id != "99" {
					items = append(items, `{"id":"`+id+`","title":"T`+id+`","albums":[{"id":9}]}`)
				}
			}
			w.Write([]byte(`{"result":[` + strings.Join(items, ",") + `]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c := New("t")
	c.base = srv.URL

	days, err := c.HistoryDays(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, d := range days {
		var ids []string
		for _, tr := range d.Tracks {
			ids = append(ids, tr.ID+"="+tr.Title)
		}
		got = append(got, fmt.Sprint(d.Date, ":", strings.Join(ids, ",")))
	}
	want := "2026-11-04:1=T1,2=T2,3=T3 2026-11-03:1=T1"
	if strings.Join(got, " ") != want {
		t.Errorf("дни = %v, ждали %s", got, want)
	}
	if models == "" || models == "0" {
		t.Errorf("fullModelsCount = %q", models)
	}
	if asked != "3,99" {
		t.Errorf("дозапрос треков = %q", asked)
	}
	if a := days[0].Tracks[0]; a.Artists != "A" || a.AlbumID != "9" || a.Duration != 1000 {
		t.Errorf("трек = %+v", a)
	}
}
