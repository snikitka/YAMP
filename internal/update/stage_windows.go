package update

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	assetName   = "YAMP-windows.zip"
	windowExe   = "yamp.exe"
	stagingName = ".update"
)

func installDir() (string, error) {
	self, err := selfPath()
	if err != nil {
		return "", err
	}
	dir := filepath.Dir(self)
	if _, err := os.Stat(filepath.Join(dir, windowExe)); err != nil {
		return "", fmt.Errorf("рядом с ядром нет %s", windowExe)
	}
	return dir, nil
}

func canInstall() bool {
	dir, err := installDir()
	return err == nil && writable(dir)
}

func stage(a asset, progress func(done, total int64)) (plan, error) {
	dir, err := installDir()
	if err != nil {
		return plan{}, err
	}
	if !writable(dir) {
		return plan{}, fmt.Errorf("нет прав на запись в папку %s", dir)
	}
	root := filepath.Join(dir, stagingName)
	os.RemoveAll(root)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return plan{}, err
	}
	archive := filepath.Join(root, assetName)
	if err := download(a, archive, progress); err != nil {
		os.RemoveAll(root)
		return plan{}, err
	}
	unpacked := filepath.Join(root, "new")
	err = unzip(archive, unpacked)
	os.Remove(archive)
	if err != nil {
		os.RemoveAll(root)
		return plan{}, fmt.Errorf("не удалось распаковать обновление: %w", err)
	}
	app, err := findApp(unpacked)
	if err != nil {
		os.RemoveAll(root)
		return plan{}, err
	}
	return plan{
		Applier: filepath.Join(root, "ymcore-update.exe"),
		Source:  app,
		Target:  dir,
		Backup:  filepath.Join(root, "old"),
		Merge:   true,
		Launch:  []string{filepath.Join(dir, windowExe)},
	}, nil
}

func unzip(archive, dir string) error {
	r, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer r.Close()
	base := filepath.Clean(dir) + string(os.PathSeparator)
	for _, f := range r.File {
		path := filepath.Join(dir, filepath.FromSlash(strings.ReplaceAll(f.Name, `\`, "/")))
		if !strings.HasPrefix(path, base) {
			return fmt.Errorf("недопустимый путь в архиве: %s", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(path, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := extract(f, path); err != nil {
			return err
		}
	}
	return nil
}

func extract(f *zip.File, path string) error {
	in, err := f.Open()
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

func findApp(root string) (string, error) {
	if _, err := os.Stat(filepath.Join(root, windowExe)); err == nil {
		return root, nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return "", err
	}
	for _, e := range entries {
		sub := filepath.Join(root, e.Name())
		if _, err := os.Stat(filepath.Join(sub, windowExe)); e.IsDir() && err == nil {
			return sub, nil
		}
	}
	return "", errors.New("в архиве обновления нет " + windowExe)
}

func Cleanup() {
	dir, err := installDir()
	if err != nil {
		return
	}
	root := filepath.Join(dir, stagingName)
	if _, err := os.Stat(root); err != nil {
		return
	}
	for range 30 {
		if os.RemoveAll(root) == nil {
			return
		}
		time.Sleep(time.Second)
	}
}
