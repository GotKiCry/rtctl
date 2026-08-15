//go:build linux

package agent

import (
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// ptySession 基于真 PTY 的交互终端（Linux/macOS）。
type ptySession struct {
	cmd  *exec.Cmd
	ptmx *os.File
	done chan struct{}
}

func newShellSession() (shellSession, error) {
	cmd := exec.Command("/bin/sh")
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, err
	}
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		close(done)
	}()
	return &ptySession{cmd: cmd, ptmx: ptmx, done: done}, nil
}

func (s *ptySession) Stdin() io.Writer { return s.ptmx }

func (s *ptySession) Output() io.Reader { return s.ptmx }

func (s *ptySession) Resize(cols, rows uint16) error {
	return pty.Setsize(s.ptmx, &pty.Winsize{Cols: cols, Rows: rows})
}

func (s *ptySession) Wait() error { <-s.done; return nil }

// Close 优雅关闭：关闭 PTY（shell 收到 EOF/SIGHUP），最多等 2 秒再强杀。
func (s *ptySession) Close() error {
	s.ptmx.Close()
	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
	}
	if s.cmd.Process != nil {
		s.cmd.Process.Kill()
	}
	return nil
}

// killProcessTree 终止整个进程组（shellExecArgs 设置了 Setpgid，
// 子进程为组长，杀 -pid 覆盖所有孙进程）。
func killProcessTree(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}

// decodeConsoleOutput Linux 上终端输出已是 UTF-8，无需转码。
func decodeConsoleOutput(b []byte) []byte { return b }
