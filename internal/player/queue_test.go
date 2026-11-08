package player

import (
	"strings"
	"testing"

	"yamp/internal/yam"
)

func tracks(ids ...string) []yam.Track {
	out := make([]yam.Track, len(ids))
	for i, id := range ids {
		out[i] = yam.Track{ID: id}
	}
	return out
}

func order(q *Queue) string {
	var ids []string
	for _, t := range q.Tracks() {
		ids = append(ids, t.ID)
	}
	return strings.Join(ids, ",")
}

func current(q *Queue) string {
	t, _ := q.Current()
	return t.ID
}

func reverse(n int, swap func(i, j int)) {
	for i := 0; i < n/2; i++ {
		swap(i, n-1-i)
	}
}

func TestQueueRepeat(t *testing.T) {
	var q Queue
	q.Set(tracks("a", "b", "c"), 1)
	if current(&q) != "b" {
		t.Fatalf("старт = %s", current(&q))
	}
	if !q.Next(true) || current(&q) != "c" {
		t.Fatalf("после b = %s", current(&q))
	}
	if q.Next(true) || current(&q) != "c" {
		t.Fatal("без повтора очередь не должна идти дальше конца")
	}

	q.SetRepeat(RepeatAll)
	if !q.Next(true) || current(&q) != "a" {
		t.Fatalf("повтор всего: после c = %s", current(&q))
	}
	if !q.Prev() || current(&q) != "c" {
		t.Fatalf("повтор всего: назад с a = %s", current(&q))
	}

	q.SetRepeat(RepeatOne)
	if !q.Next(true) || current(&q) != "c" {
		t.Fatalf("повтор трека: автопереход = %s", current(&q))
	}
	if !q.Next(false) || current(&q) != "a" {
		t.Fatalf("повтор трека: ручной переход = %s", current(&q))
	}
	if p, ok := q.Peek(); !ok || p.ID != "a" {
		t.Errorf("повтор трека: следующий = %v %v", p.ID, ok)
	}

	q.SetRepeat(RepeatOff)
	if !q.Prev() || current(&q) != "a" {
		t.Errorf("назад с первого без повтора = %s", current(&q))
	}
}

func TestQueueShuffle(t *testing.T) {
	q := Queue{shuffler: reverse}
	q.Set(tracks("a", "b", "c", "d", "e"), 2)
	q.SetShuffle(true)
	if order(&q) != "c,e,d,b,a" || q.Pos() != 0 {
		t.Fatalf("перемешано = %s pos=%d", order(&q), q.Pos())
	}
	q.Next(true)
	if current(&q) != "e" {
		t.Fatalf("после c = %s", current(&q))
	}
	q.SetShuffle(false)
	if order(&q) != "a,b,c,d,e" || current(&q) != "e" {
		t.Fatalf("без перемешивания = %s, играет %s", order(&q), current(&q))
	}

	q.SetShuffle(true)
	q.Set(tracks("a", "b", "c"), 0)
	if order(&q) != "a,c,b" {
		t.Fatalf("Set с перемешиванием = %s", order(&q))
	}
	q.SetRepeat(RepeatAll)
	q.Next(true)
	q.Next(true)
	if _, ok := q.Peek(); ok {
		t.Error("на стыке кругов следующий трек заранее не известен")
	}
	q.Next(true)
	if q.Pos() != 0 || current(&q) == "b" || order(&q)[len(order(&q))-1:] != "b" {
		t.Errorf("новый круг = %s, играет %s", order(&q), current(&q))
	}
}

func TestQueueAppendRemoveJump(t *testing.T) {
	var q Queue
	q.Set(tracks("a", "b"), 0)
	q.Append(tracks("c", "d"))
	if q.Len() != 4 || q.Remaining() != 3 {
		t.Fatalf("len=%d remaining=%d", q.Len(), q.Remaining())
	}
	if !q.Jump(2) || current(&q) != "c" {
		t.Fatalf("переход = %s", current(&q))
	}
	if q.Jump(9) || q.Remove(2) {
		t.Fatal("нельзя прыгнуть за край и удалить играющий трек")
	}
	if !q.Remove(0) || order(&q) != "b,c,d" || current(&q) != "c" || q.Pos() != 1 {
		t.Fatalf("после удаления = %s, играет %s, pos=%d", order(&q), current(&q), q.Pos())
	}
	played := q.Played()
	if len(played) != 2 || played[1].ID != "c" {
		t.Errorf("сыгранные = %v", played)
	}
	q.Clear()
	if _, ok := q.Current(); ok || q.Next(false) || q.Prev() {
		t.Error("пустая очередь")
	}
}
