package gui

import (
	"os"
	"sync"
	"time"

	"yamp/internal/update"
)

type selfUpdate struct {
	mu      sync.Mutex
	checked bool
	running bool
	result  *update.Result
}

func (g *App) startUpdates() {
	if r, ok := update.TakeResult(); ok {
		g.upd.result = &r
	}
	go update.Cleanup()
}

func (g *App) onReady() {
	g.upd.mu.Lock()
	r := g.upd.result
	g.upd.result = nil
	first := !g.upd.checked
	g.upd.checked = true
	g.upd.mu.Unlock()

	if r != nil {
		if r.Error != "" {
			g.logf("Не удалось обновить YAMP до %s: %s", r.Version, r.Error)
			g.notice("Не удалось обновить YAMP: "+r.Error, "error")
		} else {
			g.logf("YAMP обновлён до %s", Version)
			g.notice("YAMP обновлён до версии "+Version, "ok")
		}
	}
	if first && update.ReleaseBuild(Version) {
		g.checkUpdate(true)
	}
}

func (g *App) checkUpdate(quiet bool) {
	go func() {
		info := update.Check(Version)
		info.Quiet = quiet
		g.emit(info)
	}()
}

func (g *App) updating() bool {
	g.upd.mu.Lock()
	defer g.upd.mu.Unlock()
	return g.upd.running
}

func (g *App) applyUpdate() {
	if g.jobs.busy() {
		g.notice("Дождитесь окончания загрузок или остановите их", "error")
		g.emit(map[string]any{"type": "updating", "error": "загрузки ещё идут"})
		return
	}
	g.upd.mu.Lock()
	if g.upd.running {
		g.upd.mu.Unlock()
		return
	}
	g.upd.running = true
	g.upd.mu.Unlock()

	g.emit(map[string]any{"type": "updating", "done": 0, "total": 0})
	go func() {
		var last time.Time
		pkg, err := update.Install(Version, os.Getppid(), func(done, total int64) {
			if now := time.Now(); done == total || now.Sub(last) >= 100*time.Millisecond {
				last = now
				g.emit(map[string]any{"type": "updating", "done": done, "total": total})
			}
		})
		if err != nil {
			g.upd.mu.Lock()
			g.upd.running = false
			g.upd.mu.Unlock()
			g.logf("Не удалось обновить YAMP: %v", err)
			g.emit(map[string]any{"type": "updating", "error": err.Error()})
			return
		}
		if pkg != "" {
			g.upd.mu.Lock()
			g.upd.running = false
			g.upd.mu.Unlock()
			g.logf("Обновление скачано, открываю установщик")
			g.emit(map[string]any{"type": "installPackage", "path": pkg})
			g.emit(map[string]any{"type": "updating", "installer": true})
			return
		}
		g.logf("Обновление скачано, YAMP перезапустится")
		g.host.post(func() {
			g.jobs.cancel(0)
			g.host.exit()
		})
	}()
}
