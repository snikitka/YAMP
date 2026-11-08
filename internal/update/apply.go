package update

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const ApplyFlag = "--apply-update"

type plan struct {
	Applier string   `json:"applier"`
	Wait    []int    `json:"wait"`
	Source  string   `json:"source"`
	Target  string   `json:"target"`
	Backup  string   `json:"backup"`
	Merge   bool     `json:"merge"`
	Launch  []string `json:"launch"`
	Temp    string   `json:"temp,omitempty"`
	Package string   `json:"package,omitempty"`
	Version string   `json:"version"`
}

func selfPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return exe, nil
}

func spawn(p plan) error {
	self, err := selfPath()
	if err != nil {
		return err
	}
	if err := copyFile(self, p.Applier, 0o755); err != nil {
		return fmt.Errorf("не удалось подготовить обновление: %w", err)
	}
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	planPath := p.Applier + ".json"
	if err := os.WriteFile(planPath, data, 0o600); err != nil {
		return err
	}
	cmd := exec.Command(p.Applier, ApplyFlag, planPath)
	cmd.Dir = filepath.Dir(p.Applier)
	detach(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("не удалось запустить обновление: %w", err)
	}
	return cmd.Process.Release()
}

func Apply(planPath string) int {
	data, err := os.ReadFile(planPath)
	if err != nil {
		return 1
	}
	var p plan
	if err := json.Unmarshal(data, &p); err != nil {
		return 1
	}
	for _, pid := range p.Wait {
		if pid > 0 {
			waitExit(pid, time.Minute)
		}
	}
	res := Result{Version: p.Version}
	if p.Merge {
		err = merge(p.Source, p.Target, p.Backup)
	} else {
		err = swap(p.Source, p.Target, p.Backup)
	}
	if err != nil {
		res.Error = err.Error()
	}
	_ = saveResult(res)
	if len(p.Launch) > 0 {
		cmd := exec.Command(p.Launch[0], p.Launch[1:]...)
		cmd.Dir = filepath.Dir(p.Launch[0])
		detach(cmd)
		if cmd.Start() == nil {
			_ = cmd.Process.Release()
		}
	}
	if p.Temp != "" {
		os.RemoveAll(p.Temp)
	}
	return 0
}

func swap(src, dst, backup string) error {
	os.RemoveAll(backup)
	if err := retry(func() error { return rename(dst, backup) }); err != nil {
		return err
	}
	if err := rename(src, dst); err != nil {
		_ = os.Rename(backup, dst)
		return err
	}
	os.RemoveAll(backup)
	return nil
}

func merge(src, dst, backup string) error {
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	os.RemoveAll(backup)
	if err := os.MkdirAll(backup, 0o755); err != nil {
		return err
	}
	var saved, placed []string
	undo := func() {
		for _, name := range placed {
			os.RemoveAll(filepath.Join(dst, name))
		}
		for _, name := range saved {
			_ = os.Rename(filepath.Join(backup, name), filepath.Join(dst, name))
		}
	}
	for _, e := range entries {
		name := e.Name()
		cur := filepath.Join(dst, name)
		if _, err := os.Lstat(cur); err == nil {
			if err := retry(func() error { return rename(cur, filepath.Join(backup, name)) }); err != nil {
				undo()
				return err
			}
			saved = append(saved, name)
		}
		if err := retry(func() error { return rename(filepath.Join(src, name), cur) }); err != nil {
			undo()
			return err
		}
		placed = append(placed, name)
	}
	return nil
}

var (
	retryFor = 20 * time.Second
	rename   = os.Rename
)

func retry(op func() error) error {
	deadline := time.Now().Add(retryFor)
	for {
		err := op()
		if err == nil || time.Now().After(deadline) {
			return err
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

func writable(dir string) bool {
	probe, err := os.MkdirTemp(dir, ".yamp-probe-")
	if err != nil {
		return false
	}
	return os.Remove(probe) == nil
}

type Result struct {
	Version string `json:"version"`
	Error   string `json:"error,omitempty"`
}

func resultPath() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "yamp", "update.json")
}

func saveResult(r Result) error {
	path := resultPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func TakeResult() (Result, bool) {
	path := resultPath()
	data, err := os.ReadFile(path)
	if err != nil {
		return Result{}, false
	}
	os.Remove(path)
	var r Result
	if json.Unmarshal(data, &r) != nil {
		return Result{}, false
	}
	return r, true
}
