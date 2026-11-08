package mobile

import (
	"os"
	"path/filepath"
	"sync"

	"yamp/internal/gui"
)

type Sink interface {
	Event(event string)
}

var (
	mu   sync.Mutex
	core *gui.Core

	sinkMu sync.Mutex
	sink   Sink
)

func Start(filesDir, cacheDir, musicDir string, s Sink) {
	sinkMu.Lock()
	sink = s
	sinkMu.Unlock()
	mu.Lock()
	defer mu.Unlock()
	if core != nil {
		return
	}
	os.Setenv("HOME", filesDir)
	os.Setenv("XDG_CONFIG_HOME", filepath.Join(filesDir, "config"))
	os.Setenv("TMPDIR", cacheDir)
	gui.DefaultDir = musicDir
	c := gui.Start(emit)
	core = c
	go func() {
		c.Wait()
		mu.Lock()
		if core == c {
			core = nil
		}
		mu.Unlock()
	}()
}

func emit(event []byte) {
	sinkMu.Lock()
	s := sink
	sinkMu.Unlock()
	if s != nil {
		s.Event(string(event))
	}
}

func Send(command string) {
	mu.Lock()
	c := core
	mu.Unlock()
	if c != nil {
		c.Send([]byte(command))
	}
}

func Running() bool {
	mu.Lock()
	defer mu.Unlock()
	return core != nil
}
