package update

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewer(t *testing.T) {
	cases := []struct {
		tag, current string
		want         bool
	}{
		{"v2.0.3", "2.0.2", true},
		{"v2.1", "2.0.9", true},
		{"v10.0.0", "9.9.9", true},
		{"v2.0.2", "2.0.2", false},
		{"v2.0.1", "2.0.2", false},
		{"v2.0.3-beta", "2.0.2", false},
		{"garbage", "2.0.2", false},
		{"v2.0.3", "dev", false},
	}
	for _, c := range cases {
		if got := newer(c.tag, c.current); got != c.want {
			t.Errorf("newer(%q, %q) = %v, want %v", c.tag, c.current, got, c.want)
		}
	}
}

func write(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestMerge(t *testing.T) {
	root := t.TempDir()
	src, dst, backup := filepath.Join(root, "new"), filepath.Join(root, "app"), filepath.Join(root, "old")
	write(t, filepath.Join(dst, "yamp.exe"), "old")
	write(t, filepath.Join(dst, "data", "a.txt"), "old")
	write(t, filepath.Join(dst, "user.txt"), "mine")
	write(t, filepath.Join(src, "yamp.exe"), "new")
	write(t, filepath.Join(src, "data", "b.txt"), "new")
	write(t, filepath.Join(src, "extra.dll"), "new")

	if err := merge(src, dst, backup); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(dst, "yamp.exe")); got != "new" {
		t.Errorf("yamp.exe = %q", got)
	}
	if _, err := os.Stat(filepath.Join(dst, "data", "a.txt")); !os.IsNotExist(err) {
		t.Errorf("old data stayed: %v", err)
	}
	if got := read(t, filepath.Join(dst, "data", "b.txt")); got != "new" {
		t.Errorf("data/b.txt = %q", got)
	}
	if got := read(t, filepath.Join(dst, "user.txt")); got != "mine" {
		t.Errorf("user.txt = %q", got)
	}
	if got := read(t, filepath.Join(backup, "yamp.exe")); got != "old" {
		t.Errorf("backup = %q", got)
	}
}

func failOn(t *testing.T, name string) {
	t.Helper()
	oldRetry, oldRename := retryFor, rename
	retryFor = 0
	rename = func(from, to string) error {
		if filepath.Base(from) == name && filepath.Base(filepath.Dir(from)) == "new" {
			return errors.New("busy")
		}
		return os.Rename(from, to)
	}
	t.Cleanup(func() { retryFor, rename = oldRetry, oldRename })
}

func TestMergeRollsBack(t *testing.T) {
	failOn(t, "b.txt")
	root := t.TempDir()
	src, dst, backup := filepath.Join(root, "new"), filepath.Join(root, "app"), filepath.Join(root, "old")
	write(t, filepath.Join(dst, "a.txt"), "old")
	write(t, filepath.Join(dst, "b.txt"), "old")
	write(t, filepath.Join(src, "a.txt"), "new")
	write(t, filepath.Join(src, "b.txt"), "new")
	write(t, filepath.Join(src, "c.txt"), "new")

	if err := merge(src, dst, backup); err == nil {
		t.Fatal("merge succeeded")
	}
	for _, name := range []string{"a.txt", "b.txt"} {
		if got := read(t, filepath.Join(dst, name)); got != "old" {
			t.Errorf("%s = %q", name, got)
		}
	}
	if _, err := os.Stat(filepath.Join(dst, "c.txt")); !os.IsNotExist(err) {
		t.Error("c.txt was placed")
	}
}

func TestSwap(t *testing.T) {
	root := t.TempDir()
	src, dst, backup := filepath.Join(root, ".YAMP.next"), filepath.Join(root, "YAMP"), filepath.Join(root, ".YAMP.old")
	write(t, src, "new")
	write(t, dst, "old")
	if err := swap(src, dst, backup); err != nil {
		t.Fatal(err)
	}
	if got := read(t, dst); got != "new" {
		t.Errorf("target = %q", got)
	}
	for _, p := range []string{src, backup} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s stayed", p)
		}
	}
}

func TestSwapKeepsOldOnFailure(t *testing.T) {
	root := t.TempDir()
	dst, backup := filepath.Join(root, "YAMP"), filepath.Join(root, ".YAMP.old")
	write(t, dst, "old")
	if err := swap(filepath.Join(root, "missing"), dst, backup); err == nil {
		t.Fatal("swap succeeded without a source")
	}
	if got := read(t, dst); got != "old" {
		t.Errorf("target = %q", got)
	}
}

func TestDownloadChecksDigest(t *testing.T) {
	body := []byte("new build")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(body) }))
	defer srv.Close()
	sum := sha256.Sum256(body)
	path := filepath.Join(t.TempDir(), "file")

	var seen int64
	good := asset{Name: "file", URL: srv.URL, Size: int64(len(body)), Digest: "sha256:" + hex.EncodeToString(sum[:])}
	if err := download(good, path, func(done, _ int64) { seen = done }); err != nil {
		t.Fatal(err)
	}
	if seen != int64(len(body)) {
		t.Errorf("progress = %d", seen)
	}

	bad := good
	bad.Digest = "sha256:" + hex.EncodeToString(make([]byte, 32))
	if err := download(bad, path, nil); err == nil {
		t.Fatal("a wrong checksum passed")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("a broken download stayed on disk")
	}

	short := good
	short.Size++
	short.Digest = ""
	if err := download(short, path, nil); err == nil {
		t.Fatal("a short download passed")
	}
}

func TestCheck(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"tag_name":     "v9.0.0",
			"html_url":     "https://example.com/v9",
			"body":         " notes ",
			"published_at": time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC),
			"assets":       []map[string]any{{"name": assetName, "browser_download_url": "x", "size": 1}},
		})
	}))
	defer srv.Close()
	old := latestReleaseURL
	latestReleaseURL = srv.URL
	defer func() { latestReleaseURL = old }()

	info := Check("2.0.2")
	if info.Error != "" || !info.Available || info.Latest != "9.0.0" || info.Notes != "notes" || info.Page != "https://example.com/v9" {
		t.Fatalf("%+v", info)
	}
	if info = Check("9.0.0"); info.Available || info.CanApply {
		t.Fatalf("%+v", info)
	}
}
