package gui

import (
	"fmt"
	"strings"
	"sync"
)

const logLimit = 256 << 10

type logBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (l *logBuffer) WriteString(s string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.buf.WriteString(s)
	if l.buf.Len() > logLimit {
		tail := l.buf.String()[l.buf.Len()-logLimit/2:]
		if i := strings.IndexByte(tail, '\n'); i >= 0 {
			tail = tail[i+1:]
		}
		l.buf.Reset()
		l.buf.WriteString(tail)
	}
}

func (l *logBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()
}

func (g *App) emit(event any) {
	g.host.sendEvent(event)
	g.forwardRemote(event)
}

func (g *App) logf(format string, args ...any) {
	line := fmt.Sprintf(format, args...)
	if !strings.HasSuffix(line, "\n") {
		line += "\n"
	}
	g.logs.WriteString(line)
	g.emit(map[string]any{"type": "log", "text": line})
}

func (g *App) notice(message, kind string) {
	g.emit(map[string]any{"type": "notice", "message": message, "kind": kind})
}
