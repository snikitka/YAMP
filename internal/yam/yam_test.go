package yam

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
)

func TestParseLink(t *testing.T) {
	cases := []struct {
		link string
		want Link
		ok   bool
	}{
		{"https://music.yandex.ru/album/123/track/456", Link{Kind: KindTrack, TrackID: "456", AlbumID: "123"}, true},
		{"music.yandex.ru/album/123/track/456?utm=x", Link{Kind: KindTrack, TrackID: "456", AlbumID: "123"}, true},
		{"https://music.yandex.com/track/456", Link{Kind: KindTrack, TrackID: "456"}, true},
		{"https://music.yandex.ru/album/123", Link{Kind: KindAlbum, AlbumID: "123"}, true},
		{"https://music.yandex.ru/artist/77/albums", Link{Kind: KindArtist, ArtistID: "77"}, true},
		{"https://music.yandex.ru/users/vasya/playlists/789", Link{Kind: KindPlaylist, Owner: "vasya", PlaylistKind: "789"}, true},
		{"https://music.yandex.ru/playlists/lk.0123456789abcdef0123456789abcdef", Link{Kind: KindPlaylist, UUID: "lk.0123456789abcdef0123456789abcdef"}, true},
		{"https://music.yandex.ru/podcast/5/episode/6", Link{Kind: KindTrack, AlbumID: "5", TrackID: "6"}, true},
		{"456", Link{Kind: KindTrack, TrackID: "456"}, true},
		{"https://example.com/album/123", Link{}, false},
		{"hello", Link{}, false},
		{"", Link{}, false},
	}
	for _, c := range cases {
		got, err := ParseLink(c.link)
		if c.ok && err != nil {
			t.Errorf("ParseLink(%q): unexpected error %v", c.link, err)
			continue
		}
		if !c.ok && err == nil {
			t.Errorf("ParseLink(%q): expected error, got %+v", c.link, got)
			continue
		}
		if c.ok && got != c.want {
			t.Errorf("ParseLink(%q) = %+v, want %+v", c.link, got, c.want)
		}
	}
}

func TestSignPath(t *testing.T) {
	if got, want := signPath("/some/path.mp3", "abc123"), "4faadf70b4380019e22eed9a56ea8b33"; got != want {
		t.Errorf("signPath = %s, want %s", got, want)
	}
}

func TestFileInfoSign(t *testing.T) {

	if got, want := fileInfoSign(1700000000, "12345"), "A8rhGDs/OL1IOCIm7vYn4rj4ieadMfXvKJn2YoqVtoc"; got != want {
		t.Errorf("fileInfoSign = %s, want %s", got, want)
	}
}

func TestSanitize(t *testing.T) {
	cases := map[string]string{
		"AC/DC":      "AC_DC",
		"a:b*c?":     "a_b_c_",
		"  padded  ": "padded",
		"dots...":    "dots",
		"CON":        "_CON",
		"":           "Unknown",
	}
	for in, want := range cases {
		if got := sanitize(in); got != want {
			t.Errorf("sanitize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLayout(t *testing.T) {
	album := &Release{Kind: KindAlbum, Title: "Группа крови", Artist: "Кино", Year: 1988}
	tr := Track{Title: "Спокойная ночь", Artists: "Кино", AlbumArtist: "Кино", Number: 3, Disc: 1, DiscTotal: 1}
	if got, want := album.TrackPath(tr), filepath.Join("Кино - Группа крови (1988)", "03. Спокойная ночь"); got != want {
		t.Errorf("album path = %q, want %q", got, want)
	}

	tr.Artists, tr.DiscTotal, tr.Disc = "Гость", 2, 2
	if got, want := album.TrackPath(tr), filepath.Join("Кино - Группа крови (1988)", "2-03. Гость - Спокойная ночь"); got != want {
		t.Errorf("compilation path = %q, want %q", got, want)
	}

	artist := &Release{Kind: KindArtist, Title: "Кино"}
	tr = Track{Title: "Кукушка", Artists: "Кино", AlbumArtist: "Кино", Album: "Чёрный альбом", Year: 1990, Number: 1, DiscTotal: 1}
	if got, want := artist.TrackPath(tr), filepath.Join("Кино", "Чёрный альбом (1990)", "01. Кукушка"); got != want {
		t.Errorf("artist path = %q, want %q", got, want)
	}

	single := &Release{Kind: KindTrack}
	if got, want := single.TrackPath(tr), "Кино - Кукушка"; got != want {
		t.Errorf("track path = %q, want %q", got, want)
	}
}

func box(typ string, parts ...[]byte) []byte {
	body := bytes.Join(parts, nil)
	out := binary.BigEndian.AppendUint32(nil, uint32(8+len(body)))
	return append(append(out, typ...), body...)
}

func u32s(vals ...uint32) []byte {
	var b []byte
	for _, v := range vals {
		b = binary.BigEndian.AppendUint32(b, v)
	}
	return b
}

func streamInfo44() []byte {
	si := make([]byte, 34)
	si[10], si[11], si[12], si[13] = 0x0A, 0xC4, 0x42, 0xF0
	return append([]byte{0x80, 0, 0, 34}, si...)
}

func frame(n int, fill byte) []byte {
	f := bytes.Repeat([]byte{fill}, n)
	f[0], f[1] = 0xff, 0xf8
	return f
}

func flacTrakBox(stbl ...[]byte) []byte {
	dfla := box("dfLa", u32s(0), streamInfo44())
	entry := box("fLaC", make([]byte, 28), dfla)
	stsd := box("stsd", u32s(0, 1), entry)
	tkhd := box("tkhd", u32s(0, 0, 0, 1), make([]byte, 64))
	mdhd := box("mdhd", u32s(0, 0, 0, 44100, 0), make([]byte, 4))
	return box("trak", tkhd, box("mdia", mdhd, box("minf", box("stbl", append([][]byte{stsd}, stbl...)...))))
}

func parseOutput(t *testing.T, out []byte) (vorbis string, si []byte, audio []byte) {
	t.Helper()
	if string(out[:4]) != "fLaC" {
		t.Fatalf("нет сигнатуры fLaC")
	}
	pos := 4
	for {
		h := out[pos : pos+4]
		n := int(h[1])<<16 | int(h[2])<<8 | int(h[3])
		data := out[pos+4 : pos+4+n]
		switch h[0] & 0x7f {
		case flacStreamInfo:
			si = data
		case flacVorbis:
			vorbis = string(data)
		}
		pos += 4 + n
		if h[0]&0x80 != 0 {
			break
		}
	}
	return vorbis, si, out[pos:]
}

func totalSamples(si []byte) uint64 {
	return uint64(si[13]&0x0f)<<32 | uint64(binary.BigEndian.Uint32(si[14:18]))
}

func TestRemuxClassic(t *testing.T) {
	f1, f2, f3 := frame(100, 1), frame(80, 2), frame(120, 3)
	pad := bytes.Repeat([]byte{0xAA}, 16)
	ftyp := box("ftyp", []byte("isom"), u32s(0))
	mdat := box("mdat", f1, f2, pad, f3)
	off1 := uint32(len(ftyp) + 8)
	off2 := off1 + uint32(len(f1)+len(f2)+len(pad))

	trak := flacTrakBox(
		box("stts", u32s(0, 1, 3, 4096)),
		box("stsc", u32s(0, 2, 1, 2, 1, 2, 1, 1)),
		box("stsz", u32s(0, 0, 3, uint32(len(f1)), uint32(len(f2)), uint32(len(f3)))),
		box("stco", u32s(0, 2, off1, off2)),
	)

	mp4 := bytes.Join([][]byte{ftyp, mdat, box("moov", trak)}, nil)

	var out bytes.Buffer
	format, err := remuxFLAC(bytes.NewReader(mp4), int64(len(mp4)), &out, Tags{Title: "Кукушка", Artist: "Кино", Track: 1, Explicit: true})
	if err != nil {
		t.Fatal(err)
	}
	if format != "FLAC 16/44.1" {
		t.Errorf("format = %q", format)
	}
	vorbis, si, audio := parseOutput(t, out.Bytes())
	if !bytes.Equal(audio, bytes.Join([][]byte{f1, f2, f3}, nil)) {
		t.Errorf("аудиокадры не совпадают: %d байт", len(audio))
	}
	if !strings.Contains(vorbis, "ITUNESADVISORY=1") {
		t.Errorf("нет пометки 18+: %q", vorbis)
	}
	if !strings.Contains(vorbis, "TITLE=Кукушка") || !strings.Contains(vorbis, "ARTIST=Кино") {
		t.Errorf("нет тегов: %q", vorbis)
	}
	if got := totalSamples(si); got != 3*4096 {
		t.Errorf("total samples = %d, want %d", got, 3*4096)
	}

	var re bytes.Buffer
	if _, err := retagFLAC(bytes.NewReader(out.Bytes()), int64(out.Len()), &re, Tags{Title: "Новое"}); err != nil {
		t.Fatal(err)
	}
	vorbis2, _, audio2 := parseOutput(t, re.Bytes())
	if !strings.Contains(vorbis2, "TITLE=Новое") || strings.Contains(vorbis2, "Кукушка") {
		t.Errorf("теги не заменились: %q", vorbis2)
	}
	if !bytes.Equal(audio2, audio) {
		t.Errorf("retag испортил аудио")
	}
}

func TestRemuxFragmented(t *testing.T) {
	f1, f2 := frame(64, 5), frame(48, 6)
	ftyp := box("ftyp", []byte("iso6"), u32s(0))
	trak := flacTrakBox(
		box("stts", u32s(0, 0)),
		box("stsc", u32s(0, 0)),
		box("stsz", u32s(0, 0, 0)),
		box("stco", u32s(0, 0)),
	)
	moov := box("moov", trak, box("mvex", box("trex", u32s(0, 1, 1, 4096, 0, 0))))

	build := func(dataOffset uint32) []byte {
		tfhd := box("tfhd", u32s(0x020000, 1))
		trun := box("trun", u32s(0x000201, 2, dataOffset, uint32(len(f1)), uint32(len(f2))))
		return box("moof", box("mfhd", u32s(0, 1)), box("traf", tfhd, trun))
	}
	moofLen := len(build(0))
	moof := build(uint32(moofLen + 8))
	mp4 := bytes.Join([][]byte{ftyp, moov, moof, box("mdat", f1, f2)}, nil)

	var out bytes.Buffer
	if _, err := remuxFLAC(bytes.NewReader(mp4), int64(len(mp4)), &out, Tags{Title: "x"}); err != nil {
		t.Fatal(err)
	}
	_, si, audio := parseOutput(t, out.Bytes())
	if !bytes.Equal(audio, append(append([]byte(nil), f1...), f2...)) {
		t.Errorf("аудиокадры не совпадают: %d байт", len(audio))
	}
	if got := totalSamples(si); got != 2*4096 {
		t.Errorf("total samples = %d", got)
	}
}

func TestRemuxNotFLAC(t *testing.T) {
	mp4 := bytes.Join([][]byte{box("ftyp", []byte("M4A "), u32s(0)), box("moov", box("trak"))}, nil)
	if _, err := remuxFLAC(bytes.NewReader(mp4), int64(len(mp4)), &bytes.Buffer{}, Tags{}); err != errNotFLAC {
		t.Errorf("err = %v, want errNotFLAC", err)
	}
}

func TestTagMP3(t *testing.T) {
	body := append([]byte{0xff, 0xfb, 0x90, 0x00}, bytes.Repeat([]byte{7}, 500)...)
	old := append([]byte{'I', 'D', '3', 3, 0, 0, 0, 0, 0, 5}, []byte("junk!")...)
	src := append(old, body...)

	var out bytes.Buffer
	if err := tagMP3(bytes.NewReader(src), int64(len(src)), &out, Tags{Title: "Тест 🎵", Explicit: true, Cover: []byte{0xff, 0xd8, 0xff}}); err != nil {
		t.Fatal(err)
	}
	b := out.Bytes()
	n := id3Size(b)
	if !bytes.Equal(b[n:], body) {
		t.Errorf("старый тег не снят или аудио испорчено")
	}
	if !bytes.Contains(b[:n], []byte("TXXX")) || !bytes.Contains(b[:n], utf16BOM("ITUNESADVISORY")) {
		t.Errorf("нет пометки 18+")
	}
	if !bytes.Contains(b[:n], []byte("TIT2")) || !bytes.Contains(b[:n], []byte("APIC")) {
		t.Errorf("нет кадров TIT2/APIC")
	}
	if !bytes.Contains(b[:n], utf16BOM("Тест 🎵")) {
		t.Errorf("заголовок не в UTF-16 (с суррогатной парой)")
	}
}

func TestStreamDecrypt(t *testing.T) {
	key := bytes.Repeat([]byte{0x42}, 16)
	plain := bytes.Repeat([]byte("fLaC-audio-"), 50000)
	block, _ := aes.NewCipher(key)
	enc := make([]byte, len(plain))
	cipher.NewCTR(block, make([]byte, 16)).XORKeyStream(enc, plain)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(enc)
	}))
	defer srv.Close()

	s := &Session{Client: New("")}
	dst := filepath.Join(t.TempDir(), "x.part")
	var last int64
	n, err := s.stream(context.Background(), source{URL: srv.URL, Key: hex.EncodeToString(key)}, dst, func(done, _ int64) { last = done })
	if err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dst)
	if n != int64(len(plain)) || !bytes.Equal(got, plain) || last != n {
		t.Errorf("расшифровка не совпала: n=%d last=%d", n, last)
	}
}

func TestArtistSelection(t *testing.T) {
	album := func(id, title string, tracks ...string) string {
		var items []string
		for _, tr := range tracks {
			items = append(items, `{"id":"`+tr+`","title":"T`+tr+`","explicit":true,"artists":[{"name":"Кино"}]}`)
		}
		return `{"result":{"id":` + id + `,"title":"` + title + `","year":1988,"artists":[{"name":"Кино"}],"volumes":[[` + strings.Join(items, ",") + `]]}}`
	}
	var fetched []string
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		fetched = append(fetched, r.URL.Path)
		mu.Unlock()
		switch r.URL.Path {
		case "/artists/1/brief-info":
			w.Write([]byte(`{"result":{"artist":{"name":"Кино","counts":{"tracks":5}}}}`))
		case "/artists/1/direct-albums":
			w.Write([]byte(`{"result":{"albums":[
				{"id":10,"title":"Группа крови","year":1988,"trackCount":2,"contentWarning":"explicit"},
				{"id":11,"title":"Кукушка","year":1990,"trackCount":2,"type":"single"},
				{"id":12,"title":"Сборник","trackCount":1,"type":"compilation"}],"pager":{"total":3}}}`))
		case "/albums/10/with-tracks":
			w.Write([]byte(album("10", "Группа крови", "101", "102")))
		case "/albums/11/with-tracks":
			w.Write([]byte(album("11", "Кукушка", "111", "112")))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	c := New("t")
	c.base = srv.URL
	l := Link{Kind: KindArtist, ArtistID: "1"}

	preview, err := c.Resolve(context.Background(), l, false)
	if err != nil {
		t.Fatal(err)
	}
	if !preview.Albums[0].Explicit || preview.Albums[1].Explicit {
		t.Errorf("пометка 18+ у альбомов: %+v", preview.Albums)
	}
	if len(preview.Albums) != 3 || preview.Albums[1].Type != "single" || preview.Albums[2].Type != "compilation" || preview.Albums[0].Type != "album" {
		t.Fatalf("albums = %+v", preview.Albums)
	}

	fetched = nil
	rel, err := c.ResolveSelected(context.Background(), l, Selection{"10": nil, "11": {"111"}})
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, tr := range rel.Tracks {
		ids = append(ids, tr.ID)
	}
	if strings.Join(ids, ",") != "101,102,111" {
		t.Errorf("tracks = %v", ids)
	}
	if slices.Contains(fetched, "/albums/12/with-tracks") {
		t.Errorf("невыбранный альбом запрошен: %v", fetched)
	}
	if !rel.Tracks[0].Explicit {
		t.Errorf("пометка 18+ у трека: %+v", rel.Tracks[0])
	}

	one, err := c.ResolveSelected(context.Background(), Link{Kind: KindAlbum, AlbumID: "11"}, Selection{"11": {"112"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(one.Tracks) != 1 || one.Tracks[0].ID != "112" || one.Kind != KindAlbum {
		t.Errorf("выбор треков альбома: %+v", one.Tracks)
	}
}

func TestOAuthDeviceFlow(t *testing.T) {
	var polls, revoked int
	var mu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		mu.Lock()
		defer mu.Unlock()
		if r.Form.Get("client_id") != clientID {
			w.WriteHeader(http.StatusBadRequest)
			w.Write([]byte(`{"error":"invalid_client"}`))
			return
		}
		switch r.URL.Path {
		case "/device/code":
			if r.Form.Get("device_id") != "dev-123456" || r.Form.Get("device_name") != "YAMP (тест)" {
				t.Errorf("device/code: %v", r.Form)
			}
			w.Write([]byte(`{"device_code":"dc","user_code":"abcd1234","verification_url":"https://ya.ru/device","interval":1,"expires_in":300}`))
		case "/token":
			if r.Form.Get("client_secret") != clientSecret {
				t.Errorf("token без client_secret")
			}
			switch r.Form.Get("grant_type") {
			case "device_code":
				polls++
				switch {
				case r.Form.Get("code") == "gone":
					w.WriteHeader(http.StatusBadRequest)
					w.Write([]byte(`{"error":"expired_token","error_description":"Code expired"}`))
				case polls < 3:
					w.WriteHeader(http.StatusBadRequest)
					w.Write([]byte(`{"error":"authorization_pending","error_description":"User has not yet authorized"}`))
				default:
					w.Write([]byte(`{"access_token":"acc","refresh_token":"ref","expires_in":31536000,"token_type":"bearer"}`))
				}
			case "refresh_token":
				if r.Form.Get("refresh_token") != "ref" {
					w.WriteHeader(http.StatusBadRequest)
					w.Write([]byte(`{"error":"invalid_grant","error_description":"Invalid refresh token"}`))
					return
				}
				w.Write([]byte(`{"access_token":"acc","refresh_token":"ref2","expires_in":31536000}`))
			}
		case "/revoke_token":
			if r.Form.Get("access_token") != "acc" || r.Form.Get("client_secret") != clientSecret {
				t.Errorf("revoke: %v", r.Form)
			}
			revoked++
			w.Write([]byte(`{"status":"ok"}`))
		}
	}))
	defer srv.Close()
	o := &OAuth{base: srv.URL, http: srv.Client()}
	ctx := context.Background()

	code, err := o.DeviceCode(ctx, "dev-123456", "YAMP (тест)")
	if err != nil || code.UserCode != "abcd1234" || code.Interval != 1 || code.ExpiresIn != 300 {
		t.Fatalf("DeviceCode = %+v, %v", code, err)
	}
	for range 2 {
		if _, err := o.PollDevice(ctx, code.DeviceCode); !errors.Is(err, ErrPending) {
			t.Fatalf("ждали ErrPending, пришло %v", err)
		}
	}
	g, err := o.PollDevice(ctx, code.DeviceCode)
	if err != nil || g.AccessToken != "acc" || g.RefreshToken != "ref" || g.ExpiresIn != 31536000 {
		t.Fatalf("PollDevice = %+v, %v", g, err)
	}
	if _, err := o.PollDevice(ctx, "gone"); !errors.Is(err, ErrExpired) {
		t.Errorf("ждали ErrExpired, пришло %v", err)
	}

	r, err := o.Refresh(ctx, "ref")
	if err != nil || r.RefreshToken != "ref2" {
		t.Errorf("Refresh = %+v, %v", r, err)
	}
	if _, err := o.Refresh(ctx, "bad"); err == nil || !strings.Contains(err.Error(), "invalid_grant") {
		t.Errorf("плохой refresh_token: %v", err)
	}
	if err := o.Revoke(ctx, "acc"); err != nil || revoked != 1 {
		t.Errorf("Revoke: %v, вызовов %d", err, revoked)
	}
}
