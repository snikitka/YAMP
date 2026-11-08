package update

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const assetName = "YAMP-macos.dmg"

func bundle() (string, error) {
	self, err := selfPath()
	if err != nil {
		return "", err
	}
	app := filepath.Dir(filepath.Dir(filepath.Dir(self)))
	if !strings.HasSuffix(app, ".app") {
		return "", errors.New("обновляться сам умеет только YAMP.app")
	}
	return app, nil
}

func canInstall() bool {
	app, err := bundle()
	return err == nil && writable(filepath.Dir(app)) && writable(app)
}

func stage(a asset, progress func(done, total int64)) (plan, error) {
	app, err := bundle()
	if err != nil {
		return plan{}, err
	}
	dir, name := filepath.Dir(app), filepath.Base(app)
	if !writable(dir) {
		return plan{}, fmt.Errorf("нет прав на запись в папку %s", dir)
	}
	tmp, err := os.MkdirTemp("", "yamp-update-")
	if err != nil {
		return plan{}, err
	}
	fail := func(err error) (plan, error) {
		os.RemoveAll(tmp)
		return plan{}, err
	}
	image := filepath.Join(tmp, assetName)
	if err := download(a, image, progress); err != nil {
		return fail(err)
	}
	next := filepath.Join(dir, "."+name+".next")
	if err := copyFromImage(image, filepath.Join(tmp, "mnt"), next); err != nil {
		os.RemoveAll(next)
		return fail(fmt.Errorf("не удалось распаковать обновление: %w", err))
	}
	os.Remove(image)
	return plan{
		Applier: filepath.Join(tmp, "ymcore"),
		Source:  next,
		Target:  app,
		Backup:  filepath.Join(dir, "."+name+".old"),
		Launch:  []string{"/usr/bin/open", app},
		Temp:    tmp,
	}, nil
}

func copyFromImage(image, mount, dst string) error {
	if err := os.MkdirAll(mount, 0o755); err != nil {
		return err
	}
	if out, err := exec.Command("hdiutil", "attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount, image).CombinedOutput(); err != nil {
		return fmt.Errorf("hdiutil attach: %v: %s", err, strings.TrimSpace(string(out)))
	}
	defer exec.Command("hdiutil", "detach", mount, "-force").Run()
	matches, _ := filepath.Glob(filepath.Join(mount, "*.app"))
	if len(matches) == 0 {
		return errors.New("в образе нет приложения")
	}
	os.RemoveAll(dst)
	if out, err := exec.Command("ditto", matches[0], dst).CombinedOutput(); err != nil {
		return fmt.Errorf("ditto: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func Cleanup() {}
