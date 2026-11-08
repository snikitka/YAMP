package player

import (
	"math/rand/v2"

	"yamp/internal/yam"
)

type Repeat string

const (
	RepeatOff Repeat = "off"
	RepeatAll Repeat = "all"
	RepeatOne Repeat = "one"
)

func ParseRepeat(s string) Repeat {
	switch Repeat(s) {
	case RepeatAll, RepeatOne:
		return Repeat(s)
	}
	return RepeatOff
}

type Queue struct {
	tracks   []yam.Track
	order    []int
	pos      int
	repeat   Repeat
	shuffle  bool
	shuffler func(n int, swap func(i, j int))
}

func (q *Queue) shuffleRange(order []int) {
	f := q.shuffler
	if f == nil {
		f = rand.Shuffle
	}
	f(len(order), func(i, j int) { order[i], order[j] = order[j], order[i] })
}

func (q *Queue) Set(tracks []yam.Track, start int) {
	q.tracks = append([]yam.Track(nil), tracks...)
	q.order = make([]int, len(q.tracks))
	for i := range q.order {
		q.order[i] = i
	}
	q.pos = 0
	if len(q.tracks) == 0 {
		return
	}
	start = max(0, min(start, len(q.tracks)-1))
	if q.shuffle {
		q.reshuffle(start)
		return
	}
	q.pos = start
}

func (q *Queue) Restore(tracks []yam.Track, pos int, shuffle bool) {
	q.shuffle = false
	q.Set(tracks, pos)
	q.shuffle = shuffle
}

func (q *Queue) reshuffle(first int) {
	rest := make([]int, 0, len(q.tracks))
	for i := range q.tracks {
		if i != first {
			rest = append(rest, i)
		}
	}
	q.shuffleRange(rest)
	q.order = append([]int{first}, rest...)
	q.pos = 0
}

func (q *Queue) Append(tracks []yam.Track) {
	for _, t := range tracks {
		q.order = append(q.order, len(q.tracks))
		q.tracks = append(q.tracks, t)
	}
}

func (q *Queue) Len() int { return len(q.order) }

func (q *Queue) Pos() int { return q.pos }

func (q *Queue) Remaining() int {
	if len(q.order) == 0 {
		return 0
	}
	return len(q.order) - q.pos - 1
}

func (q *Queue) Repeat() Repeat {
	if q.repeat == "" {
		return RepeatOff
	}
	return q.repeat
}

func (q *Queue) Shuffle() bool { return q.shuffle }

func (q *Queue) Current() (yam.Track, bool) {
	if q.pos < 0 || q.pos >= len(q.order) {
		return yam.Track{}, false
	}
	return q.tracks[q.order[q.pos]], true
}

func (q *Queue) Tracks() []yam.Track {
	out := make([]yam.Track, len(q.order))
	for i, idx := range q.order {
		out[i] = q.tracks[idx]
	}
	return out
}

func (q *Queue) Played() []yam.Track {
	if len(q.order) == 0 {
		return nil
	}
	return q.Tracks()[:q.pos+1]
}

func (q *Queue) nextPos(auto bool) (int, bool) {
	n := len(q.order)
	switch {
	case n == 0:
		return 0, false
	case auto && q.Repeat() == RepeatOne:
		return q.pos, true
	case q.pos+1 < n:
		return q.pos + 1, true
	case q.Repeat() != RepeatOff:
		return 0, true
	}
	return q.pos, false
}

func (q *Queue) Peek() (yam.Track, bool) {
	p, ok := q.nextPos(true)
	if !ok || (p == q.pos && q.Repeat() != RepeatOne) {
		return yam.Track{}, false
	}
	if p == 0 && q.pos+1 >= len(q.order) && q.shuffle && q.Repeat() == RepeatAll {
		return yam.Track{}, false
	}
	return q.tracks[q.order[p]], true
}

func (q *Queue) Next(auto bool) bool {
	p, ok := q.nextPos(auto)
	if !ok {
		return false
	}
	if p == 0 && q.pos+1 >= len(q.order) && q.shuffle {
		cur := q.order[q.pos]
		q.reshuffle(cur)
		if len(q.order) > 1 {
			q.order = append(q.order[1:], q.order[0])
		}
		q.pos = 0
		return true
	}
	q.pos = p
	return true
}

func (q *Queue) Prev() bool {
	switch {
	case len(q.order) == 0:
		return false
	case q.pos > 0:
		q.pos--
	case q.Repeat() == RepeatAll:
		q.pos = len(q.order) - 1
	}
	return true
}

func (q *Queue) Jump(pos int) bool {
	if pos < 0 || pos >= len(q.order) {
		return false
	}
	q.pos = pos
	return true
}

func (q *Queue) SetRepeat(r Repeat) { q.repeat = r }

func (q *Queue) SetShuffle(on bool) {
	if on == q.shuffle {
		return
	}
	q.shuffle = on
	if len(q.order) == 0 {
		return
	}
	cur := q.order[q.pos]
	if on {
		q.reshuffle(cur)
		return
	}
	for i := range q.order {
		q.order[i] = i
	}
	q.pos = cur
}

func (q *Queue) Remove(pos int) bool {
	if pos < 0 || pos >= len(q.order) || pos == q.pos {
		return false
	}
	idx := q.order[pos]
	q.order = append(q.order[:pos], q.order[pos+1:]...)
	for i, v := range q.order {
		if v > idx {
			q.order[i] = v - 1
		}
	}
	q.tracks = append(q.tracks[:idx], q.tracks[idx+1:]...)
	if pos < q.pos {
		q.pos--
	}
	return true
}

func (q *Queue) Clear() {
	q.tracks, q.order, q.pos = nil, nil, 0
}
