package main

import (
	"bufio"
	"io"
	"log"
	"os"

	"yamp/internal/gui"
	"yamp/internal/update"
)

const maxCommand = 16 << 20

func main() {
	if len(os.Args) == 3 && os.Args[1] == update.ApplyFlag {
		os.Exit(update.Apply(os.Args[2]))
	}
	serve(os.Stdin, os.Stdout)
}

func serve(in io.Reader, out io.Writer) {
	core := gui.Start(func(event []byte) {
		_, _ = out.Write(append(event, '\n'))
	})
	go func() {
		lines := bufio.NewScanner(in)
		lines.Buffer(make([]byte, 64<<10), maxCommand)
		for lines.Scan() {
			core.Send(lines.Bytes())
		}
		if err := lines.Err(); err != nil {
			log.Print("Соединение с окном разорвано: ", err)
		}
		core.Close()
	}()
	core.Wait()
}
