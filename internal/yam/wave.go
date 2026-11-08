package yam

import (
	"context"
	"errors"
	"time"
)

const (
	WaveSeed = "user:onyourwave"
	WaveFrom = "radio-mobile-user-onyourwave"
)

type WaveBatch struct {
	Session string
	Batch   string
	Tracks  []Track
	Liked   map[string]bool
}

type apiWaveBatch struct {
	RadioSessionID string `json:"radioSessionId"`
	BatchID        string `json:"batchId"`
	UnknownSession bool   `json:"unknownSession"`
	Terminated     bool   `json:"terminated"`
	Sequence       []struct {
		Type  string    `json:"type"`
		Track *apiTrack `json:"track"`
		Liked bool      `json:"liked"`
	} `json:"sequence"`
}

var ErrWaveEnded = errors.New("волна закончилась, запустите её заново")

func (b apiWaveBatch) shape(session string) WaveBatch {
	if b.RadioSessionID != "" {
		session = b.RadioSessionID
	}
	out := WaveBatch{Session: session, Batch: b.BatchID, Liked: map[string]bool{}}
	for _, it := range b.Sequence {
		if it.Track == nil || (it.Type != "" && it.Type != "track") {
			continue
		}
		tr := it.Track.shape(nil)
		if tr.ID == "" || !tr.Available {
			continue
		}
		out.Tracks = append(out.Tracks, tr)
		if it.Liked {
			out.Liked[tr.ID] = true
		}
	}
	return out
}

func waveQueue(queue []Track) []string {
	ids := make([]string, 0, len(queue))
	for _, t := range queue {
		id := t.ID
		if t.AlbumID != "" {
			id += ":" + t.AlbumID
		}
		ids = append(ids, id)
	}
	return ids
}

func (c *Client) WaveStart(ctx context.Context, seeds []string, queue []Track) (WaveBatch, error) {
	if len(seeds) == 0 {
		seeds = []string{WaveSeed}
	}
	body := map[string]any{"seeds": seeds, "includeTracksInResponse": true}
	if len(queue) > 0 {
		body["queue"] = waveQueue(queue)
	}
	var r apiWaveBatch
	if err := c.postJSON(ctx, "/rotor/session/new", body, &r); err != nil {
		return WaveBatch{}, err
	}
	if r.RadioSessionID == "" {
		return WaveBatch{}, errors.New("Яндекс не создал сессию волны")
	}
	return r.shape(""), nil
}

func (c *Client) WaveNext(ctx context.Context, session string, queue []Track) (WaveBatch, error) {
	var r apiWaveBatch
	body := map[string]any{"queue": waveQueue(queue)}
	if err := c.postJSON(ctx, "/rotor/session/"+session+"/tracks", body, &r); err != nil {
		return WaveBatch{}, err
	}
	if r.UnknownSession || r.Terminated {
		return WaveBatch{}, ErrWaveEnded
	}
	return r.shape(session), nil
}

type WaveEvent string

const (
	WaveStarted       WaveEvent = "radioStarted"
	WaveTrackStarted  WaveEvent = "trackStarted"
	WaveTrackFinished WaveEvent = "trackFinished"
	WaveSkip          WaveEvent = "skip"
)

func (c *Client) WaveFeedback(ctx context.Context, session, batch string, ev WaveEvent, trackID string, played float64) error {
	event := map[string]any{
		"type":      string(ev),
		"timestamp": time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
	}
	if trackID != "" {
		event["trackId"] = trackID
	}
	if ev == WaveTrackFinished || ev == WaveSkip {
		event["totalPlayedSeconds"] = max(played, 0)
	}
	body := map[string]any{"event": event}
	if batch != "" {
		body["batchId"] = batch
	}
	if ev == WaveStarted {
		body["from"] = WaveFrom
	}
	var out any
	return c.postJSON(ctx, "/rotor/session/"+session+"/feedback", body, &out)
}
