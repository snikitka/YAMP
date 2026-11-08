//go:build android

package update

import (
	"os"
	"path/filepath"
	"runtime"
)

var assetName = "YAMP-android-" + map[string]string{"arm64": "arm64", "arm": "arm", "amd64": "x86_64"}[runtime.GOARCH] + ".apk"

func updateDir() string { return filepath.Join(os.TempDir(), "update") }

func canInstall() bool { return true }

func stage(a asset, progress func(done, total int64)) (plan, error) {
	dir := updateDir()
	os.RemoveAll(dir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return plan{}, err
	}
	path := filepath.Join(dir, a.Name)
	if err := download(a, path, progress); err != nil {
		return plan{}, err
	}
	return plan{Package: path}, nil
}

func Cleanup() { os.RemoveAll(updateDir()) }
