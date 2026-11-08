package gui

import (
	"context"
	"encoding/json"
	"net/netip"
	"strings"
	"testing"
	"time"

	"yamp/internal/remote"
)

func TestRemoteAllowlist(t *testing.T) {
	allowed := map[string]string{
		`{"cmd":"playerNext"}`:                       `{"cmd":"playerNext","position":42,"track":"1"}`,
		`{"cmd":"playerPrev","track":"1"}`:           `{"cmd":"playerPrev","position":42,"track":"1"}`,
		`{"cmd":"playerJump","pos":3}`:               `{"cmd":"playerJump","pos":3,"position":42}`,
		`{"cmd":"like","on":true}`:                   `{"cmd":"like","on":true,"position":42,"track":"1"}`,
		`{"cmd":"dislike","track":"9","on":true}`:    `{"cmd":"dislike","on":true,"position":42,"track":"9"}`,
		`{"cmd":"playerRepeat","repeat":"one"}`:      `{"cmd":"playerRepeat","repeat":"one"}`,
		`{"cmd":"playerShuffle","on":true}`:          `{"cmd":"playerShuffle","on":true}`,
		`{"cmd":"queue","source":"x"}`:               `{"cmd":"queue"}`,
		`{"cmd":"playerState"}`:                      `{"cmd":"playerState"}`,
		`{"cmd":"pause"}`:                            `{"action":"pause","type":"remote"}`,
		`{"cmd":"resume"}`:                           `{"action":"resume","type":"remote"}`,
		`{"cmd":"seek","position":12.5}`:             `{"action":"seek","position":12.5,"type":"remote"}`,
		`{"cmd":"volume","volume":7}`:                `{"action":"volume","type":"remote","volume":1}`,
		`{"cmd":"playerNext","token":"t","dir":"/"}`: `{"cmd":"playerNext","position":42,"track":"1"}`,

		`{"cmd":"play","source":"wave"}`:                                                `{"cmd":"play","index":0,"source":"wave","track":""}`,
		`{"cmd":"play","source":"liked","track":"123","index":4}`:                       `{"cmd":"play","index":4,"source":"liked","track":"123"}`,
		`{"cmd":"play","source":"history","index":-1}`:                                  `{"cmd":"play","index":-1,"source":"history","track":""}`,
		`{"cmd":"play","source":"chart","seeds":["user:x"]}`:                            `{"cmd":"play","index":0,"source":"chart","track":""}`,
		`{"cmd":"play","source":"https://music.yandex.ru/album/5/track/6","track":"6"}`: `{"cmd":"play","index":0,"source":"https://music.yandex.ru/album/5/track/6","track":"6"}`,
		`{"cmd":"play","source":"https://music.yandex.ru/artist/9/tracks"}`:             `{"cmd":"play","index":0,"source":"https://music.yandex.ru/artist/9/tracks","track":""}`,
		`{"cmd":"wave","source":"https://music.yandex.ru/artist/9","title":" Кино\n"}`:  `{"cmd":"wave","source":"https://music.yandex.ru/artist/9","title":"Кино","track":""}`,
		`{"cmd":"wave","track":"77"}`:                                                   `{"cmd":"wave","source":"","title":"","track":"77"}`,
	}
	for in, want := range allowed {
		act, ok := translateRemote([]byte(in), "1", 42)
		if !ok {
			t.Errorf("%s не пропустили", in)
			continue
		}
		out := act.core
		if out == nil {
			out = act.ui
		}
		got, _ := json.Marshal(out)
		if string(got) != want {
			t.Errorf("%s превратилось в %s, ждали %s", in, got, want)
		}
	}
	if act, ok := translateRemote([]byte(`{"cmd":"unpair"}`), "1", 0); !ok || !act.unpair {
		t.Error("unpair не распознан")
	}

	denied := []string{
		`{"cmd":"play"}`, `{"cmd":"play","source":"home"}`, `{"cmd":"play","source":"https://evil.example.com/album/1"}`,
		`{"cmd":"play","source":"C:\\Windows"}`, `{"cmd":"play","source":"playlist:1"}`, `{"cmd":"play","source":"wave","track":"12a"}`,
		`{"cmd":"play","source":"wave","track":"../1"}`, `{"cmd":"play","source":"wave","track":"123456789012345678901"}`,
		`{"cmd":"play","source":"wave","index":-2}`, `{"cmd":"play","source":"wave","index":100001}`,
		`{"cmd":"play","source":"https://music.yandex.ru/album/1 x"}`,
		`{"cmd":"play","source":"https://music.yandex.ru/album/1?` + strings.Repeat("a", 600) + `"}`,
		`{"cmd":"wave"}`, `{"cmd":"wave","source":"liked"}`, `{"cmd":"wave","source":"wave"}`, `{"cmd":"wave","track":"x"}`,
		`{"cmd":"login","token":"x"}`, `{"cmd":"logout"}`,
		`{"cmd":"exit"}`, `{"cmd":"prefs","dir":"C:\\"}`, `{"cmd":"download","link":"x"}`, `{"cmd":"cancel"}`,
		`{"cmd":"applyUpdate"}`, `{"cmd":"checkUpdate"}`, `{"cmd":"deviceLogin"}`, `{"cmd":"recheck"}`,
		`{"cmd":"playerEnded","track":"1"}`, `{"cmd":"playerStarted","track":"1"}`, `{"cmd":"playerError","track":"1"}`,
		`{"cmd":"playerPosition","track":"1"}`, `{"cmd":"playerVolume","volume":1}`, `{"cmd":"playerQuality"}`,
		`{"cmd":"playQuality"}`, `{"cmd":"network"}`, `{"cmd":"presence"}`, `{"cmd":"search"}`, `{"cmd":"open"}`,
		`{"cmd":"remotePair"}`, `{"cmd":"remoteUnpair","id":"x"}`, `{"cmd":"remoteSend"}`, `{"cmd":"ready"}`,
		`{"cmd":"playerNext","track":"2"}`, `{"cmd":"playerJump"}`, `{"cmd":"playerJump","pos":-1}`,
		`{"cmd":"seek"}`, `{"cmd":"seek","position":-3}`, `{"cmd":"volume"}`, `{"cmd":""}`, `not json`,
	}
	for _, in := range denied {
		if _, ok := translateRemote([]byte(in), "1", 0); ok {
			t.Errorf("%s пропустили", in)
		}
	}
	if _, ok := translateRemote([]byte(`{"cmd":"playerNext"}`), "", 0); ok {
		t.Error("переключили трек, когда ничего не играет")
	}
	if _, ok := translateRemote([]byte(`{"cmd":"like","on":true}`), "", 0); ok {
		t.Error("лайк без трека")
	}
}

func stubRemoteNet(t *testing.T) {
	oldPort, oldAnnounce, oldListen, oldHosts := remotePort, remoteAnnounce, remoteListen, remoteHosts
	remotePort = 0
	remoteAnnounce = func(ctx context.Context, _ time.Duration, _ func() remote.Beacon) error {
		<-ctx.Done()
		return nil
	}
	remoteListen = func(ctx context.Context, _ func(remote.Beacon, netip.Addr)) error {
		<-ctx.Done()
		return nil
	}
	remoteHosts = func(int) []string { return []string{"127.0.0.1"} }
	t.Cleanup(func() {
		remotePort, remoteAnnounce, remoteListen, remoteHosts = oldPort, oldAnnounce, oldListen, oldHosts
	})
}

func pairLink(t *testing.T, c *Core, log *eventLog) remote.PairLink {
	t.Helper()
	send(c, map[string]any{"cmd": "remotePair"})
	ev := log.wait(t, "remoteHost", func(ev map[string]any) bool { s, _ := ev["link"].(string); return s != "" })
	if ev["running"] != true {
		t.Fatalf("сервер пульта не запущен: %v", ev)
	}
	l, err := remote.ParseLink(ev["link"].(string))
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func readType(t *testing.T, conn *remote.Conn, typ string, ok func(map[string]any) bool) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		line, err := conn.Read()
		if err != nil {
			t.Fatalf("ждали %s от компьютера: %v", typ, err)
		}
		var ev map[string]any
		if json.Unmarshal(line, &ev) == nil && ev["type"] == typ && (ok == nil || ok(ev)) {
			return ev
		}
	}
	t.Fatalf("не дождались %s от компьютера", typ)
	return nil
}

func TestRemoteHost(t *testing.T) {
	stubRemoteNet(t)
	c, _, log := startPlayerCore(t)
	t.Cleanup(c.app.closeRemote)

	send(c, map[string]any{"cmd": "play", "source": "wave"})
	log.wait(t, "player", playing("1", "play"))

	l := pairLink(t, c, log)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := remote.Dial(ctx, l.Addrs(), l.FP)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	w, err := conn.Hello(remote.Hello{Op: remote.OpPair, ID: "phone", Name: "Пиксель", Secret: l.Secret})
	if err != nil || !w.OK || w.Key == "" {
		t.Fatalf("связывание: %+v, %v", w, err)
	}
	if n := log.wait(t, "notice", nil); !strings.Contains(n["message"].(string), "Пиксель") {
		t.Errorf("уведомление о связи: %v", n)
	}

	player := readType(t, conn, "player", nil)
	if tr, _ := player["track"].(map[string]any); tr == nil || tr["id"] != "1" {
		t.Fatalf("снимок плеера: %v", player)
	}
	for _, k := range []string{"url", "nextUrl", "action"} {
		if _, has := player[k]; has {
			t.Errorf("в снимке для пульта есть %s: %v", k, player[k])
		}
	}
	readType(t, conn, "queue", nil)
	if pb := readType(t, conn, "playback", nil); pb["track"] != "1" || pb["playing"] != false {
		t.Fatalf("снимок воспроизведения: %v", pb)
	}

	send(c, map[string]any{"cmd": "playerPosition", "track": "1", "position": 5, "playing": true})
	pb := readType(t, conn, "playback", func(ev map[string]any) bool { return ev["playing"] == true })
	if pos, _ := pb["position"].(float64); pos < 5 || pos > 6 {
		t.Errorf("позиция для пульта = %v", pb["position"])
	}

	for _, cmd := range []string{`{"cmd":"pause"}`, `{"cmd":"seek","position":30}`, `{"cmd":"volume","volume":0.3}`} {
		if err := conn.Send([]byte(cmd)); err != nil {
			t.Fatal(err)
		}
	}
	if ev := log.wait(t, "remote", nil); ev["action"] != "pause" {
		t.Errorf("ждали паузу, пришло %v", ev)
	}
	if ev := log.wait(t, "remote", nil); ev["action"] != "seek" || ev["position"] != 30.0 {
		t.Errorf("ждали перемотку, пришло %v", ev)
	}
	if ev := log.wait(t, "remote", nil); ev["action"] != "volume" || ev["volume"] != 0.3 {
		t.Errorf("ждали громкость, пришло %v", ev)
	}

	for _, cmd := range []string{`{"cmd":"logout"}`, `{"cmd":"play","source":"liked"}`, `{"cmd":"exit"}`, `{"cmd":"playerNext","track":"7"}`, `{"cmd":"playerNext","track":"1"}`} {
		if err := conn.Send([]byte(cmd)); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.After(5 * time.Second)
	for done := false; !done; {
		select {
		case ev := <-log.ch:
			switch {
			case ev["type"] == "account" || ev["type"] == "exit":
				t.Fatalf("пульт выполнил запрещённую команду: %v", ev)
			case ev["type"] == "player" && playing("2", "play")(ev):
				done = true
			case ev["type"] == "player":
				if tr, _ := ev["track"].(map[string]any); tr != nil && tr["id"] != "1" && tr["id"] != "2" {
					t.Fatalf("пульт запустил другой источник: %v", ev)
				}
			}
		case <-deadline:
			t.Fatal("playerNext с пульта не переключил трек")
		}
	}
	readType(t, conn, "player", func(ev map[string]any) bool {
		tr, _ := ev["track"].(map[string]any)
		return tr != nil && tr["id"] == "2"
	})

	if err := conn.Send([]byte(`{"cmd":"like","on":true}`)); err != nil {
		t.Fatal(err)
	}
	if m := readType(t, conn, "mark", nil); m["track"] != "2" || m["liked"] != true {
		t.Errorf("лайк с пульта: %v", m)
	}

	stranger, err := remote.Dial(ctx, l.Addrs(), l.FP)
	if err != nil {
		t.Fatal(err)
	}
	if w, err := stranger.Hello(remote.Hello{Op: remote.OpAuth, ID: "phone", Key: w.Key + "x"}); err != nil || w.OK {
		t.Fatalf("пустили с чужим ключом: %+v, %v", w, err)
	}
	stranger.Close()

	send(c, map[string]any{"cmd": "remoteUnpair", "device": "phone"})
	for {
		if _, err := conn.Read(); err != nil {
			break
		}
	}
	log.wait(t, "remoteHost", func(ev map[string]any) bool {
		devices, _ := ev["devices"].([]any)
		return len(devices) == 0 && ev["running"] == false
	})
}

func TestRemotePhone(t *testing.T) {
	stubRemoteNet(t)
	pc, _, pcLog := startPlayerCore(t)
	t.Cleanup(pc.app.closeRemote)
	send(pc, map[string]any{"cmd": "play", "source": "wave"})
	pcLog.wait(t, "player", playing("1", "play"))
	l := pairLink(t, pc, pcLog)

	phoneDir := t.TempDir()
	for _, v := range []string{"AppData", "HOME", "XDG_CONFIG_HOME"} {
		t.Setenv(v, phoneDir)
	}
	phoneLog := &eventLog{ch: make(chan map[string]any, 256)}
	phone := Start(func(b []byte) {
		var ev map[string]any
		if json.Unmarshal(b, &ev) == nil {
			select {
			case phoneLog.ch <- ev:
			default:
			}
		}
	})
	t.Cleanup(func() {
		phone.app.closeRemote()
		phone.Close()
		phone.Wait()
	})

	send(phone, map[string]any{"cmd": "remotePairLink", "link": "yamp://pair?nope"})
	if ev := phoneLog.wait(t, "remoteLink", nil); ev["status"] != linkFailed {
		t.Fatalf("плохой код: %v", ev)
	}

	stale := l
	stale.Secret = "stale"
	send(phone, map[string]any{"cmd": "remotePairLink", "link": stale.String(), "name": "Пиксель"})
	if ev := phoneLog.wait(t, "remoteLink", func(ev map[string]any) bool { return ev["status"] != linkPairing }); ev["status"] != linkFailed {
		t.Fatalf("старый секрет: %v", ev)
	}

	l = pairLink(t, pc, pcLog)
	send(phone, map[string]any{"cmd": "remotePairLink", "link": l.String(), "name": "Пиксель"})
	devices := phoneLog.wait(t, "remoteDevices", nil)
	if list, _ := devices["devices"].([]any); len(list) != 1 || list[0].(map[string]any)["paired"] != true {
		t.Fatalf("список компьютеров: %v", devices)
	}
	phoneLog.wait(t, "remoteLink", func(ev map[string]any) bool { return ev["status"] == linkOnline && ev["id"] == l.ID })
	remoteEvent := func(typ string, ok func(map[string]any) bool) map[string]any {
		t.Helper()
		return phoneLog.wait(t, "remoteEvent", func(ev map[string]any) bool {
			inner, _ := ev["event"].(map[string]any)
			return inner != nil && inner["type"] == typ && (ok == nil || ok(inner))
		})["event"].(map[string]any)
	}
	remoteEvent("player", func(ev map[string]any) bool {
		tr, _ := ev["track"].(map[string]any)
		return tr != nil && tr["id"] == "1"
	})

	send(phone, map[string]any{"cmd": "remoteSend", "command": map[string]any{"cmd": "playerNext", "track": "1"}})
	pcLog.wait(t, "player", playing("2", "play"))
	remoteEvent("player", func(ev map[string]any) bool {
		tr, _ := ev["track"].(map[string]any)
		return tr != nil && tr["id"] == "2"
	})

	send(phone, map[string]any{"cmd": "remoteSend", "command": map[string]any{"cmd": "pause"}})
	if ev := pcLog.wait(t, "remote", nil); ev["action"] != "pause" {
		t.Fatalf("пауза с телефона: %v", ev)
	}

	send(phone, map[string]any{"cmd": "remoteSend", "command": map[string]any{"cmd": "play", "source": "wave"}})
	pcLog.wait(t, "player", playing("1", "play"))
	remoteEvent("player", func(ev map[string]any) bool {
		tr, _ := ev["track"].(map[string]any)
		return tr != nil && tr["id"] == "1"
	})

	send(phone, map[string]any{"cmd": "remoteDisconnect"})
	phoneLog.wait(t, "remoteLink", func(ev map[string]any) bool { return ev["status"] == linkIdle })
	send(phone, map[string]any{"cmd": "remoteConnect", "device": l.ID})
	phoneLog.wait(t, "remoteLink", func(ev map[string]any) bool { return ev["status"] == linkOnline })

	send(phone, map[string]any{"cmd": "remoteForget", "device": l.ID})
	pcLog.wait(t, "remoteHost", func(ev map[string]any) bool {
		list, _ := ev["devices"].([]any)
		return len(list) == 0
	})
	phoneLog.wait(t, "remoteDevices", func(ev map[string]any) bool {
		list, _ := ev["devices"].([]any)
		return len(list) == 0
	})
}
