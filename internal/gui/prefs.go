package gui

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"yamp/internal/player"
	"yamp/internal/yam"
)

const (
	minConcurrency     = 1
	maxConcurrency     = 8
	defaultConcurrency = 4
)

type config struct {
	Dir         string `json:"dir"`
	Theme       string `json:"theme"`
	Quality     string `json:"quality"`
	Concurrency int    `json:"concurrency"`

	PlayQuality   string   `json:"playQuality,omitempty"`
	AutoQuality   *bool    `json:"autoQuality,omitempty"`
	WifiQuality   string   `json:"wifiQuality,omitempty"`
	MobileQuality string   `json:"mobileQuality,omitempty"`
	Volume        *float64 `json:"volume,omitempty"`
	Repeat        string   `json:"repeat,omitempty"`
	Shuffle       bool     `json:"shuffle,omitempty"`
	Discord       *bool    `json:"discord,omitempty"`
	Crossfade     *bool    `json:"crossfade,omitempty"`
	Fade          int      `json:"fade,omitempty"`

	Token    string `json:"token,omitempty"`
	Refresh  string `json:"refresh,omitempty"`
	Expires  int64  `json:"expires,omitempty"`
	DeviceID string `json:"deviceId,omitempty"`
}

var DefaultDir string

func defaultDir() string {
	if DefaultDir != "" {
		return DefaultDir
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, "Music", "Yandex Music Downloads")
}

func defaultConfig() config {
	return config{
		Dir:         defaultDir(),
		Theme:       "dark",
		Quality:     string(yam.Lossless),
		Concurrency: defaultConcurrency,
	}
}

func configPath() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "yamp", "config.json")
}

func loadConfig() config {
	c := defaultConfig()
	if b, err := os.ReadFile(configPath()); err == nil {
		var saved config
		if json.Unmarshal(b, &saved) == nil {
			if saved.Dir != "" {
				c.Dir = saved.Dir
			}
			if saved.Theme != "" {
				c.Theme = saved.Theme
			}
			if saved.Quality == string(yam.MP3) {
				c.Quality = saved.Quality
			}
			if saved.Concurrency != 0 {
				c.Concurrency = clampConcurrency(saved.Concurrency)
			}
			c.Token, c.Refresh, c.Expires, c.DeviceID = saved.Token, saved.Refresh, saved.Expires, saved.DeviceID
			c.PlayQuality = string(playQuality(saved.PlayQuality))
			c.AutoQuality = saved.AutoQuality
			c.WifiQuality = string(playQuality(saved.WifiQuality))
			c.MobileQuality = string(c.mobileQuality())
			if saved.MobileQuality != "" {
				c.MobileQuality = string(playQuality(saved.MobileQuality))
			}
			if saved.Volume != nil {
				v := clampVolume(*saved.Volume)
				c.Volume = &v
			}
			c.Repeat = string(player.ParseRepeat(saved.Repeat))
			c.Shuffle = saved.Shuffle
			c.Discord = saved.Discord
			c.Crossfade = saved.Crossfade
			if saved.Fade != 0 {
				c.Fade = clampFade(saved.Fade)
			}
		}
	}
	return c
}

func clampConcurrency(n int) int {
	return max(minConcurrency, min(maxConcurrency, n))
}

const (
	minFade     = 1
	maxFade     = 12
	defaultFade = 6
)

func clampFade(n int) int {
	return max(minFade, min(maxFade, n))
}

func (c config) crossfade() bool {
	return c.Crossfade == nil || *c.Crossfade
}

func (c config) fade() int {
	if c.Fade == 0 {
		return defaultFade
	}
	return clampFade(c.Fade)
}

const defaultVolume = 0.8

func clampVolume(v float64) float64 {
	if v != v {
		return defaultVolume
	}
	return max(0, min(1, v))
}

func (c config) volume() float64 {
	if c.Volume == nil {
		return defaultVolume
	}
	return *c.Volume
}

func playQuality(s string) yam.Quality {
	switch yam.Quality(s) {
	case yam.MP3, yam.Low:
		return yam.Quality(s)
	}
	return yam.Lossless
}

func (c config) autoQuality() bool {
	return c.AutoQuality == nil || *c.AutoQuality
}

func (c config) wifiQuality() yam.Quality {
	return playQuality(c.WifiQuality)
}

func (c config) mobileQuality() yam.Quality {
	if c.MobileQuality == "" {
		return yam.MP3
	}
	return playQuality(c.MobileQuality)
}

func (c config) playback(metered bool) yam.Quality {
	switch {
	case !c.autoQuality():
		return playQuality(c.PlayQuality)
	case metered:
		return c.mobileQuality()
	}
	return c.wifiQuality()
}

func (c config) quality() yam.Quality {
	if c.Quality == string(yam.MP3) {
		return yam.MP3
	}
	return yam.Lossless
}

func unseal(v string) string {
	if v == "" {
		return ""
	}
	sealed, err := base64.StdEncoding.DecodeString(v)
	if err != nil {
		return ""
	}
	plain, err := unprotect(sealed)
	if err != nil {
		return ""
	}
	return string(plain)
}

func seal(plain string) (string, error) {
	if plain == "" {
		return "", nil
	}
	sealed, err := protect([]byte(plain))
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(sealed), nil
}

func (c config) token() string { return unseal(c.Token) }

func (c config) refresh() string { return unseal(c.Refresh) }

func (c *config) setToken(token string) (err error) {
	c.Token, err = seal(token)
	return err
}

func (c *config) setGrant(g *yam.Grant) (err error) {
	if g == nil {
		c.Refresh, c.Expires = "", 0
		return nil
	}
	c.Refresh, err = seal(g.RefreshToken)
	c.Expires = g.Expires(time.Now()).Unix()
	return err
}

func (c config) save() error {
	path := configPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
