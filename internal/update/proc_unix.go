//go:build !windows

package update

import (
	"errors"
	"os/exec"
	"syscall"
	"time"
)

func waitExit(pid int, limit time.Duration) {
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}
