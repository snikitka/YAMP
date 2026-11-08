package update

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"
)

func makeZip(t *testing.T, path string, files map[string]string) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	w := zip.NewWriter(f)
	for name, data := range files {
		fw, err := w.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		fw.Write([]byte(data))
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestUnzipFindsApp(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(root, "a.zip")
	makeZip(t, archive, map[string]string{
		"YAMP/yamp.exe":                  "w",
		"YAMP/ymcore.exe":                "c",
		"YAMP/data/flutter_assets/a.bin": "x",
	})
	out := filepath.Join(root, "out")
	if err := unzip(archive, out); err != nil {
		t.Fatal(err)
	}
	app, err := findApp(out)
	if err != nil {
		t.Fatal(err)
	}
	if app != filepath.Join(out, "YAMP") {
		t.Errorf("app = %s", app)
	}
	if got := read(t, filepath.Join(app, "data", "flutter_assets", "a.bin")); got != "x" {
		t.Errorf("a.bin = %q", got)
	}
}

func TestUnzipRejectsEscape(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(root, "a.zip")
	makeZip(t, archive, map[string]string{"../evil.exe": "x"})
	if err := unzip(archive, filepath.Join(root, "out")); err == nil {
		t.Fatal("an entry outside the folder passed")
	}
	if _, err := os.Stat(filepath.Join(root, "evil.exe")); !os.IsNotExist(err) {
		t.Error("evil.exe was written")
	}
}
