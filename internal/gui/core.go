package gui

import (
	"encoding/json"
	"sync"
)

type Core struct {
	app *App

	outMu  sync.Mutex
	emit   func(event []byte)
	closed bool

	queueMu sync.Mutex
	queue   []func()
	wake    chan struct{}
	done    chan struct{}
	exiting sync.Once
}

func Start(emit func(event []byte)) *Core {
	c := &Core{emit: emit, wake: make(chan struct{}, 1), done: make(chan struct{})}
	c.app = newApp()
	c.app.host = c
	c.app.start()
	go c.loop()
	return c
}

func (c *Core) Send(command []byte) {
	var head struct {
		Cmd string `json:"cmd"`
	}
	if json.Unmarshal(command, &head) != nil || head.Cmd == "" {
		return
	}
	line := string(command)
	c.post(func() { c.app.onMessage(line) })
}

func (c *Core) Close() {
	c.post(func() {
		c.app.jobs.cancel(0)
		c.exit()
	})
}

func (c *Core) Wait() {
	<-c.done
}

func (c *Core) loop() {
	for {
		select {
		case <-c.wake:
		case <-c.done:
			return
		}
		c.queueMu.Lock()
		q := c.queue
		c.queue = nil
		c.queueMu.Unlock()
		for _, f := range q {
			f()
		}
	}
}

func (c *Core) post(f func()) {
	c.queueMu.Lock()
	c.queue = append(c.queue, f)
	c.queueMu.Unlock()
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

func (c *Core) send(event []byte) {
	c.outMu.Lock()
	defer c.outMu.Unlock()
	if c.closed {
		return
	}
	c.emit(event)
}

func (c *Core) sendEvent(event any) {
	if data, err := json.Marshal(event); err == nil {
		c.send(data)
	}
}

func (c *Core) exit() {
	c.exiting.Do(func() {
		c.sendEvent(map[string]any{"type": "exit"})
		c.outMu.Lock()
		c.closed = true
		c.outMu.Unlock()
		close(c.done)
	})
}
