package update

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	repo         = "TheGreatPepix/YAMP"
	releasesPage = "https://github.com/" + repo + "/releases"
)

var latestReleaseURL = "https://api.github.com/repos/" + repo + "/releases/latest"

var (
	apiClient      = &http.Client{Timeout: 30 * time.Second}
	downloadClient = &http.Client{Timeout: 30 * time.Minute}
)

type asset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Size   int64  `json:"size"`
	Digest string `json:"digest"`
}

type release struct {
	Tag       string    `json:"tag_name"`
	Page      string    `json:"html_url"`
	Notes     string    `json:"body"`
	Published time.Time `json:"published_at"`
	Draft     bool      `json:"draft"`
	Assets    []asset   `json:"assets"`
}

func (r release) asset(name string) (asset, bool) {
	for _, a := range r.Assets {
		if strings.EqualFold(a.Name, name) {
			return a, true
		}
	}
	return asset{}, false
}

func latestRelease(current string) (release, error) {
	req, err := http.NewRequest(http.MethodGet, latestReleaseURL, nil)
	if err != nil {
		return release{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "YAMP/"+current)
	resp, err := apiClient.Do(req)
	if err != nil {
		return release{}, fmt.Errorf("нет связи с GitHub: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return release{}, errors.New("на GitHub ещё нет релизов")
	case resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusTooManyRequests:
		return release{}, errors.New("GitHub ограничил запросы с этого адреса, попробуйте через час")
	case resp.StatusCode != http.StatusOK:
		return release{}, fmt.Errorf("GitHub ответил %s", resp.Status)
	}
	var r release
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&r); err != nil {
		return release{}, fmt.Errorf("не удалось прочитать релиз: %w", err)
	}
	if r.Tag == "" || r.Draft {
		return release{}, errors.New("GitHub не вернул релиз")
	}
	if r.Page == "" {
		r.Page = releasesPage + "/tag/" + r.Tag
	}
	return r, nil
}

func parseVersion(v string) (core [3]int, suffix string, ok bool) {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	main, suffix, _ := strings.Cut(v, "-")
	main, _, _ = strings.Cut(main, "+")
	parts := strings.Split(main, ".")
	if len(parts) > 3 {
		return core, "", false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return core, "", false
		}
		core[i] = n
	}
	return core, suffix, true
}

func newer(tag, current string) bool {
	t, suffix, ok := parseVersion(tag)
	if !ok || suffix != "" {
		return false
	}
	c, _, ok := parseVersion(current)
	if !ok {
		return false
	}
	for i := range t {
		if t[i] != c[i] {
			return t[i] > c[i]
		}
	}
	return false
}

func ReleaseBuild(v string) bool {
	_, _, ok := parseVersion(v)
	return ok
}

func download(a asset, path string, progress func(done, total int64)) error {
	resp, err := downloadClient.Get(a.URL)
	if err != nil {
		return fmt.Errorf("загрузка %s: %w", a.Name, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("загрузка %s: %s", a.Name, resp.Status)
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	sum := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, sum, &counter{total: a.Size, report: progress}), io.LimitReader(resp.Body, a.Size+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && n != a.Size {
		err = fmt.Errorf("загрузка %s: получено %d байт вместо %d", a.Name, n, a.Size)
	}
	if want, ok := strings.CutPrefix(a.Digest, "sha256:"); err == nil && ok && !strings.EqualFold(want, hex.EncodeToString(sum.Sum(nil))) {
		err = fmt.Errorf("загрузка %s: контрольная сумма не совпадает", a.Name)
	}
	if err != nil {
		os.Remove(path)
		return err
	}
	return nil
}

type counter struct {
	done, total int64
	report      func(done, total int64)
}

func (c *counter) Write(p []byte) (int, error) {
	c.done += int64(len(p))
	if c.report != nil {
		c.report(c.done, c.total)
	}
	return len(p), nil
}

type Info struct {
	Type      string `json:"type"`
	Current   string `json:"current"`
	Latest    string `json:"latest,omitempty"`
	Page      string `json:"page"`
	Notes     string `json:"notes,omitempty"`
	Published string `json:"published,omitempty"`
	Available bool   `json:"available"`
	CanApply  bool   `json:"canApply"`
	Quiet     bool   `json:"quiet,omitempty"`
	Error     string `json:"error,omitempty"`
}

func Check(current string) Info {
	info := Info{Type: "update", Current: current, Page: releasesPage + "/latest"}
	r, err := latestRelease(current)
	if err != nil {
		info.Error = err.Error()
		return info
	}
	info.Latest = strings.TrimPrefix(r.Tag, "v")
	info.Page, info.Notes = r.Page, strings.TrimSpace(r.Notes)
	if !r.Published.IsZero() {
		info.Published = r.Published.Local().Format("02.01.2006")
	}
	info.Available = newer(r.Tag, current)
	_, hasAsset := r.asset(assetName)
	info.CanApply = info.Available && hasAsset && canInstall()
	return info
}

func Install(current string, windowPID int, progress func(done, total int64)) (string, error) {
	r, err := latestRelease(current)
	if err != nil {
		return "", err
	}
	if !newer(r.Tag, current) {
		return "", fmt.Errorf("YAMP %s уже последней версии", current)
	}
	a, ok := r.asset(assetName)
	if !ok {
		return "", fmt.Errorf("в релизе %s нет файла %s, скачайте его со страницы %s", r.Tag, assetName, r.Page)
	}
	p, err := stage(a, progress)
	if err != nil {
		return "", err
	}
	if p.Package != "" {
		return p.Package, nil
	}
	p.Wait = []int{windowPID, os.Getpid()}
	p.Version = strings.TrimPrefix(r.Tag, "v")
	return "", spawn(p)
}
