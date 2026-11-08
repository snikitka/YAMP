package gui

type uiState struct {
	Type        string `json:"type"`
	Dir         string `json:"dir"`
	Theme       string `json:"theme"`
	Quality     string `json:"quality"`
	Concurrency int    `json:"concurrency"`
	Version     string `json:"version"`
	Discord     bool   `json:"discord"`
	DiscordOK   bool   `json:"discordAvailable"`
	PlayAuto    bool   `json:"playAuto"`
	PlayManual  string `json:"playManual"`
	PlayWifi    string `json:"playWifi"`
	PlayMobile  string `json:"playMobile"`
	PlayNow     string `json:"playQuality"`
	Metered     bool   `json:"metered"`
	Crossfade   bool   `json:"crossfade"`
	Fade        int    `json:"fade"`
	Log         string `json:"log,omitempty"`
}

func (g *App) emitState(withLog bool) {
	g.mu.Lock()
	s := uiState{
		Type:        "state",
		Dir:         g.cfg.Dir,
		Theme:       g.cfg.Theme,
		Quality:     string(g.cfg.quality()),
		Concurrency: g.cfg.Concurrency,
		Version:     Version,
		Discord:     g.cfg.discord(),
		DiscordOK:   g.discord.Enabled(),
		PlayAuto:    g.cfg.autoQuality(),
		PlayManual:  string(playQuality(g.cfg.PlayQuality)),
		PlayWifi:    string(g.cfg.wifiQuality()),
		PlayMobile:  string(g.cfg.mobileQuality()),
		PlayNow:     string(g.cfg.playback(g.metered)),
		Metered:     g.metered,
		Crossfade:   g.cfg.crossfade(),
		Fade:        g.cfg.fade(),
	}
	g.mu.Unlock()
	if withLog {
		s.Log = g.logs.String()
	}
	g.emit(s)
}
