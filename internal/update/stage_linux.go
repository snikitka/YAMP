//go:build linux && !android

package update

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

const assetName = "YAMP-linux-x86_64.AppImage"

func appImage() (string, error) {
	path := os.Getenv("APPIMAGE")
	if path == "" || runtime.GOARCH != "amd64" {
		return "", errors.New("обновляться сам умеет только AppImage для x86_64")
	}
	return path, nil
}

func canInstall() bool {
	path, err := appImage()
	return err == nil && writable(filepath.Dir(path))
}

func stage(a asset, progress func(done, total int64)) (plan, error) {
	target, err := appImage()
	if err != nil {
		return plan{}, err
	}
	dir, name := filepath.Dir(target), filepath.Base(target)
	if !writable(dir) {
		return plan{}, fmt.Errorf("нет прав на запись в папку %s", dir)
	}
	next := filepath.Join(dir, "."+name+".next")
	if err := download(a, next, progress); err != nil {
		return plan{}, err
	}
	if err := os.Chmod(next, 0o755); err != nil {
		os.Remove(next)
		return plan{}, err
	}
	tmp, err := os.MkdirTemp("", "yamp-update-")
	if err != nil {
		os.Remove(next)
		return plan{}, err
	}
	return plan{
		Applier: filepath.Join(tmp, "ymcore"),
		Source:  next,
		Target:  target,
		Backup:  filepath.Join(dir, "."+name+".old"),
		Launch:  []string{target},
		Temp:    tmp,
	}, nil
}

func Cleanup() {}
