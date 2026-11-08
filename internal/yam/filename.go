package yam

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
)

var invalidChars = regexp.MustCompile(`[<>:"/\\|?*\x00-\x1f]`)

var reservedNames = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true,
	"COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true,
	"LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

func sanitize(name string) string {
	s := invalidChars.ReplaceAllString(name, "_")
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 120 {
		s = string(r[:120])
	}
	s = strings.TrimRight(s, ". ")
	if s == "" {
		return "Unknown"
	}
	if reservedNames[strings.ToUpper(s)] {
		s = "_" + s
	}
	return s
}

func withYear(name string, year int) string {
	if year > 0 {
		return fmt.Sprintf("%s (%d)", name, year)
	}
	return name
}

func (r *Release) Folder() string {
	switch r.Kind {
	case KindAlbum:
		name := r.Title
		if r.Artist != "" {
			name = r.Artist + " - " + name
		}
		return sanitize(withYear(name, r.Year))
	case KindPlaylist, KindArtist:
		return sanitize(r.Title)
	}
	return ""
}

func (r *Release) TrackPath(t Track) string {
	plain := sanitize(t.Artists) + " - " + sanitize(t.Title)
	numbered := func() string {
		num := fmt.Sprintf("%02d", t.Number)
		if t.DiscTotal > 1 {
			num = fmt.Sprintf("%d-%02d", t.Disc, t.Number)
		}
		name := t.Title

		if t.Artists != "" && t.Artists != t.AlbumArtist {
			name = t.Artists + " - " + name
		}
		if t.Number <= 0 {
			return sanitize(name)
		}
		return num + ". " + sanitize(name)
	}

	switch r.Kind {
	case KindAlbum:
		return filepath.Join(r.Folder(), numbered())
	case KindArtist:
		return filepath.Join(r.Folder(), sanitize(withYear(t.Album, t.Year)), numbered())
	case KindPlaylist:
		return filepath.Join(r.Folder(), plain)
	}
	return plain
}
