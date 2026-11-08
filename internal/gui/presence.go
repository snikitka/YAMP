package gui

import (
	"runtime"
	"strings"
	"time"

	"yamp/internal/discord"
)

var DiscordClientID = "1567570649399042221"

func discordID() string {
	if runtime.GOOS == "android" {
		return ""
	}
	return DiscordClientID
}

func (c config) discord() bool { return c.Discord == nil || *c.Discord }

func (g *App) setPresence(c uiCommand) {
	var a *discord.Activity
	if c.Playing && strings.TrimSpace(c.Title) != "" {
		start := time.Now().Add(-time.Duration(c.Position * float64(time.Second)))
		a = &discord.Activity{
			Title:  c.Title,
			Artist: c.Artist,
			Album:  c.Album,
			Cover:  c.Cover,
			Link:   c.Link,
			Start:  start,
		}
		if c.Duration > 0 {
			a.End = start.Add(time.Duration(c.Duration * float64(time.Second)))
		}
	}
	g.mu.Lock()
	g.presence = a
	on := g.cfg.discord()
	g.mu.Unlock()
	if on {
		g.discord.Set(a)
	}
}

func (g *App) applyPresence() {
	g.mu.Lock()
	a := g.presence
	if !g.cfg.discord() {
		a = nil
	}
	g.mu.Unlock()
	g.discord.Set(a)
}
