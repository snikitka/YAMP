package discord

import (
	"errors"
	"fmt"
	"io"
	"os"
)

func dial() (io.ReadWriteCloser, error) {
	for i := range 10 {
		f, err := os.OpenFile(fmt.Sprintf(`\\.\pipe\discord-ipc-%d`, i), os.O_RDWR, 0)
		if err == nil {
			return f, nil
		}
	}
	return nil, errors.New("discord не запущен")
}
