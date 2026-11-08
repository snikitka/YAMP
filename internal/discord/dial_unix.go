//go:build !windows

package discord

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
)

func dial() (io.ReadWriteCloser, error) {
	var bases []string
	for _, k := range []string{"XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"} {
		if v := os.Getenv(k); v != "" {
			bases = append(bases, v)
		}
	}
	bases = append(bases, "/tmp")
	for _, base := range bases {
		for _, sub := range []string{"", "app/com.discordapp.Discord", "snap.discord", ".flatpak/dev.vencord.Vesktop/xdg-run"} {
			for i := range 10 {
				conn, err := net.Dial("unix", filepath.Join(base, sub, fmt.Sprintf("discord-ipc-%d", i)))
				if err == nil {
					return conn, nil
				}
			}
		}
	}
	return nil, errors.New("discord не запущен")
}
