package yam

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

type LyricsKind string

const (
	LyricsUnknown LyricsKind = ""
	LyricsNone    LyricsKind = "none"
	LyricsText    LyricsKind = "text"
	LyricsSync    LyricsKind = "sync"
)

type LyricLine struct {
	Ms   int    `json:"ms"`
	Text string `json:"text"`
}

type Lyrics struct {
	Synced  bool
	Lines   []LyricLine
	Writers []string
}

type apiLyricsInfo struct {
	Sync bool `json:"hasAvailableSyncLyrics"`
	Text bool `json:"hasAvailableTextLyrics"`
}

func (i *apiLyricsInfo) kind() LyricsKind {
	switch {
	case i == nil:
		return LyricsUnknown
	case i.Sync:
		return LyricsSync
	case i.Text:
		return LyricsText
	}
	return LyricsNone
}

func lyricsSign(trackID string, ts int64) string {
	mac := hmac.New(sha256.New, []byte(fileInfoKey))
	mac.Write([]byte(trackID + strconv.FormatInt(ts, 10)))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func (c *Client) lyricsFile(ctx context.Context, trackID, format string) (string, []string, error) {
	ts := time.Now().Unix()
	q := url.Values{
		"format":    {format},
		"timeStamp": {strconv.FormatInt(ts, 10)},
		"sign":      {lyricsSign(trackID, ts)},
	}
	var r struct {
		DownloadURL string   `json:"downloadUrl"`
		Writers     []string `json:"writers"`
	}
	if err := c.api(ctx, http.MethodGet, "/tracks/"+url.PathEscape(trackID)+"/lyrics?"+q.Encode(), nil, &r); err != nil {
		return "", nil, err
	}
	if r.DownloadURL == "" {
		return "", nil, &APIError{Status: http.StatusNotFound}
	}
	b, err := c.fetch(ctx, http.MethodGet, r.DownloadURL, nil, false)
	if err != nil {
		return "", nil, err
	}
	return string(b), r.Writers, nil
}

func missing(err error) bool {
	var ae *APIError
	return errors.As(err, &ae) && (ae.Status == http.StatusNotFound || ae.Status == http.StatusOK)
}

func (c *Client) Lyrics(ctx context.Context, trackID string, kind LyricsKind) (Lyrics, error) {
	if kind == LyricsNone {
		return Lyrics{}, nil
	}
	if kind != LyricsText {
		body, writers, err := c.lyricsFile(ctx, trackID, "LRC")
		if err == nil {
			if lines := ParseLRC(body); len(lines) > 0 {
				return Lyrics{Synced: true, Lines: lines, Writers: writers}, nil
			}
		} else if !missing(err) {
			return Lyrics{}, err
		}
	}
	body, writers, err := c.lyricsFile(ctx, trackID, "TEXT")
	if missing(err) {
		return Lyrics{}, nil
	}
	if err != nil {
		return Lyrics{}, err
	}
	return Lyrics{Lines: textLines(body), Writers: writers}, nil
}

var lrcStampRe = regexp.MustCompile(`^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]`)

func ParseLRC(body string) []LyricLine {
	var out []LyricLine
	for _, raw := range strings.Split(strings.ReplaceAll(body, "\r", ""), "\n") {
		line := strings.TrimSpace(raw)
		var stamps []int
		for {
			m := lrcStampRe.FindStringSubmatch(line)
			if m == nil {
				break
			}
			mm, _ := strconv.Atoi(m[1])
			sec, _ := strconv.Atoi(m[2])
			ms := 0
			if frac := m[3]; frac != "" {
				n, _ := strconv.Atoi(frac)
				for i := len(frac); i < 3; i++ {
					n *= 10
				}
				ms = n
			}
			stamps = append(stamps, (mm*60+sec)*1000+ms)
			line = strings.TrimSpace(line[len(m[0]):])
		}
		for _, at := range stamps {
			out = append(out, LyricLine{Ms: at, Text: line})
		}
	}
	slices.SortStableFunc(out, func(a, b LyricLine) int { return a.Ms - b.Ms })
	for len(out) > 0 && out[len(out)-1].Text == "" {
		out = out[:len(out)-1]
	}
	return out
}

func textLines(body string) []LyricLine {
	lines := strings.Split(strings.TrimSpace(strings.ReplaceAll(body, "\r", "")), "\n")
	out := make([]LyricLine, 0, len(lines))
	for _, l := range lines {
		out = append(out, LyricLine{Ms: -1, Text: strings.TrimSpace(l)})
	}
	if len(out) == 1 && out[0].Text == "" {
		return nil
	}
	return out
}
