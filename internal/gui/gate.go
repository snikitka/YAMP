package gui

import (
	"context"
	"sync"
)

type gate struct {
	mu      sync.Mutex
	limit   int
	active  int
	waiters []chan struct{}
}

func newGate(limit int) *gate {
	return &gate{limit: limit}
}

func (g *gate) acquire(ctx context.Context) error {
	g.mu.Lock()
	if g.active < g.limit && len(g.waiters) == 0 {
		g.active++
		g.mu.Unlock()
		return nil
	}
	ch := make(chan struct{})
	g.waiters = append(g.waiters, ch)
	g.mu.Unlock()

	select {
	case <-ch:
		return nil
	case <-ctx.Done():
		g.mu.Lock()
		defer g.mu.Unlock()
		for i, w := range g.waiters {
			if w == ch {
				g.waiters = append(g.waiters[:i], g.waiters[i+1:]...)
				return ctx.Err()
			}
		}

		g.active--
		g.wake()
		return ctx.Err()
	}
}

func (g *gate) release() {
	g.mu.Lock()
	g.active--
	g.wake()
	g.mu.Unlock()
}

func (g *gate) setLimit(n int) {
	g.mu.Lock()
	g.limit = n
	g.wake()
	g.mu.Unlock()
}

func (g *gate) wake() {
	for g.active < g.limit && len(g.waiters) > 0 {
		ch := g.waiters[0]
		g.waiters = g.waiters[1:]
		g.active++
		close(ch)
	}
}
