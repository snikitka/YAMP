package yam

import (
	"context"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type Quality string

const (
	Lossless Quality = "lossless"

	MP3 Quality = "mp3"

	Low Quality = "low"
)

const (
	signSalt      = "XGRlBW9FXlekgbPrRHuSiA"
	fileInfoKey   = "p93jhgh689SBReK6ghtw62"
	fileInfoCodec = "flac,flac-mp4,mp3,aac,he-aac,aac-mp4,he-aac-mp4"
	transports    = "encraw"
)

type source struct {
	URL     string
	Codec   string
	Bitrate int
	Key     string
}

func isFlacCodec(c string) bool {
	c = strings.ToLower(c)
	return c == "flac" || c == "flac-mp4"
}

func signPath(path, s string) string {
	sum := md5.Sum([]byte(signSalt + strings.TrimPrefix(path, "/") + s))
	return hex.EncodeToString(sum[:])
}

func fileInfoSign(ts int64, trackID string) string {
	msg := strconv.FormatInt(ts, 10) + trackID + "lossless" +
		strings.ReplaceAll(fileInfoCodec, ",", "") + transports
	mac := hmac.New(sha256.New, []byte(fileInfoKey))
	mac.Write([]byte(msg))
	s := base64.StdEncoding.EncodeToString(mac.Sum(nil))
	return s[:len(s)-1]
}

func (c *Client) losslessSource(ctx context.Context, trackID string) (source, error) {
	ts := time.Now().Unix()
	q := url.Values{
		"ts":         {strconv.FormatInt(ts, 10)},
		"trackId":    {trackID},
		"quality":    {"lossless"},
		"codecs":     {fileInfoCodec},
		"transports": {transports},
		"sign":       {fileInfoSign(ts, trackID)},
	}
	var r struct {
		DownloadInfo struct {
			Codec   string   `json:"codec"`
			Bitrate int      `json:"bitrate"`
			Key     string   `json:"key"`
			URLs    []string `json:"urls"`
			URL     string   `json:"url"`
		} `json:"downloadInfo"`
	}
	if err := c.api(ctx, http.MethodGet, "/get-file-info?"+q.Encode(), nil, &r); err != nil {
		return source{}, err
	}
	d := r.DownloadInfo
	link := d.URL
	if len(d.URLs) > 0 {
		link = d.URLs[0]
	}
	if link == "" {
		return source{}, errors.New("get-file-info не вернул ссылку")
	}
	return source{URL: link, Codec: strings.ToLower(d.Codec), Bitrate: d.Bitrate, Key: d.Key}, nil
}

func (c *Client) mp3Source(ctx context.Context, trackID string, low bool) (source, error) {
	var infos []struct {
		Codec           string `json:"codec"`
		BitrateInKbps   int    `json:"bitrateInKbps"`
		DownloadInfoURL string `json:"downloadInfoUrl"`
	}
	if err := c.api(ctx, http.MethodGet, "/tracks/"+trackID+"/download-info", nil, &infos); err != nil {
		return source{}, err
	}
	best := -1
	for i, it := range infos {
		if it.DownloadInfoURL == "" {
			continue
		}
		if best < 0 {
			best = i
			continue
		}
		b := infos[best]
		isMP3, bestMP3 := it.Codec == "mp3", b.Codec == "mp3"
		better := it.BitrateInKbps > b.BitrateInKbps
		if low {
			better = it.BitrateInKbps < b.BitrateInKbps
		}
		if (isMP3 && !bestMP3) || (isMP3 == bestMP3 && better) {
			best = i
		}
	}
	if best < 0 {
		return source{}, errors.New("Яндекс не вернул ссылок на скачивание")
	}
	pick := infos[best]

	infoURL := pick.DownloadInfoURL
	if strings.Contains(infoURL, "?") {
		infoURL += "&format=json"
	} else {
		infoURL += "?format=json"
	}

	b, err := c.fetch(ctx, http.MethodGet, infoURL, nil, false)
	if err != nil {
		return source{}, err
	}
	var d struct {
		Host string `json:"host" xml:"host"`
		Path string `json:"path" xml:"path"`
		Ts   string `json:"ts" xml:"ts"`
		S    string `json:"s" xml:"s"`
	}
	if json.Unmarshal(b, &d) != nil {
		if err := xml.Unmarshal(b, &d); err != nil {
			return source{}, fmt.Errorf("некорректный ответ download-info (%s)", snippet(b))
		}
	}
	if d.Host == "" || d.Path == "" {
		return source{}, errors.New("некорректный ответ download-info")
	}
	return source{
		URL:     fmt.Sprintf("https://%s/get-mp3/%s/%s%s", d.Host, signPath(d.Path, d.S), d.Ts, d.Path),
		Codec:   pick.Codec,
		Bitrate: pick.BitrateInKbps,
	}, nil
}

func (c *Client) audioSource(ctx context.Context, trackID string, q Quality) (source, error) {
	if q == Lossless {
		s, err := c.losslessSource(ctx, trackID)
		if err == nil && isFlacCodec(s.Codec) && s.Key != "" {
			return s, nil
		}
		if err != nil && (errors.Is(err, ErrUnauthorized) || ctx.Err() != nil) {
			return source{}, err
		}
	}
	return c.mp3Source(ctx, trackID, q == Low)
}
