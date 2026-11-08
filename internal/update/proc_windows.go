package update

import (
	"os/exec"
	"syscall"
	"time"
)

const (
	detachedProcess       = 0x00000008
	createNewProcessGroup = 0x00000200
)

func waitExit(pid int, limit time.Duration) {
	h, err := syscall.OpenProcess(syscall.SYNCHRONIZE, false, uint32(pid))
	if err != nil {
		return
	}
	defer syscall.CloseHandle(h)
	_, _ = syscall.WaitForSingleObject(h, uint32(limit.Milliseconds()))
}

func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: detachedProcess | createNewProcessGroup}
}
