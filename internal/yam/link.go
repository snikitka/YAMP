package yam

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

type Kind string

const (
	KindTrack    Kind = "track"
	KindAlbum    Kind = "album"
	KindPlaylist Kind = "playlist"
	KindArtist   Kind = "artist"
)

type Link struct {
	Kind         Kind
	TrackID      string
	AlbumID      string
	ArtistID     string
	Owner        string
	PlaylistKind string
	UUID         string
}

var (
	trackInAlbumRe = regexp.MustCompile(`/album/(\d+)/track/(\d+)`)
	trackRe        = regexp.MustCompile(`/track/(\d+)`)
	albumRe        = regexp.MustCompile(`/album/(\d+)`)
	episodeRe      = regexp.MustCompile(`/podcast/(\d+)/episode/(\d+)`)
	podcastRe      = regexp.MustCompile(`/podcast/(\d+)`)
	artistRe       = regexp.MustCompile(`/artist/(\d+)`)
	playlistRe     = regexp.MustCompile(`/users/([^/]+)/playlists/(\d+)`)
	uuidPlaylistRe = regexp.MustCompile(`(?i)/playlists/((?:[a-z]{1,4}\.)?[a-f0-9-]{32,40})`)
	digitsRe       = regexp.MustCompile(`^\d+$`)
)

var errBadLink = errors.New("Не удалось распознать ссылку.\n\nПоддерживаются ссылки на трек, альбом, исполнителя и плейлист music.yandex.ru")

func ParseLink(link string) (Link, error) {
	s := strings.TrimSpace(link)
	if s == "" {
		return Link{}, errBadLink
	}

	if digitsRe.MatchString(s) {
		return Link{Kind: KindTrack, TrackID: s}, nil
	}

	if !strings.Contains(s, "://") {
		s = "https://" + s
	}
	u, err := url.Parse(s)
	if err != nil {
		return Link{}, errBadLink
	}
	if host := strings.ToLower(u.Hostname()); !strings.Contains(host, "yandex.") {
		return Link{}, errBadLink
	}
	p := u.Path

	if m := trackInAlbumRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindTrack, AlbumID: m[1], TrackID: m[2]}, nil
	}
	if m := trackRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindTrack, TrackID: m[1]}, nil
	}
	if m := albumRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindAlbum, AlbumID: m[1]}, nil
	}

	if m := episodeRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindTrack, AlbumID: m[1], TrackID: m[2]}, nil
	}
	if m := podcastRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindAlbum, AlbumID: m[1]}, nil
	}
	if m := artistRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindArtist, ArtistID: m[1]}, nil
	}
	if m := playlistRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindPlaylist, Owner: m[1], PlaylistKind: m[2]}, nil
	}
	if m := uuidPlaylistRe.FindStringSubmatch(p); m != nil {
		return Link{Kind: KindPlaylist, UUID: m[1]}, nil
	}
	return Link{}, errBadLink
}
