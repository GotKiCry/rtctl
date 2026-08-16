//go:build linux

package agent

import (
	"io"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
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
// sudo=true 时无法直接按组杀：sudo 会为目标命令新建会话/进程组，
// Setpgid 的组 ID（sudo 自身 pid）覆盖不到 /bin/sh 与孙进程。
// 因此经 /proc 遍历后代 pid，再用一次 sudo kill 全部终止。
func killProcessTree(cmd *exec.Cmd, sudo bool) {
	if cmd.Process == nil {
		return
	}
	pgid := -cmd.Process.Pid
	if !sudo {
		_ = syscall.Kill(pgid, syscall.SIGKILL)
		return
	}
	pids := descendantPids(cmd.Process.Pid)
	pids = append([]int{cmd.Process.Pid}, pids...) // 根（sudo）+ 全部后代一次杀
	pidStrs := make([]string, len(pids))
	for i, p := range pids {
		pidStrs[i] = strconv.Itoa(p)
	}
	// 单次 sudo：/bin/sh 已在 sudoers 放行，kill 多个 pid 一次完成
	k := exec.Command("sudo", "-n", "--", "/bin/sh", "-c",
		"/usr/bin/kill -KILL "+strings.Join(pidStrs, " "))
	var errBuf strings.Builder
	k.Stdout = io.Discard
	k.Stderr = &errBuf
	err := k.Run()
	log.Printf("[agent] killProcessTree(sudo): root=%d pids=%v err=%v stderr=%q",
		cmd.Process.Pid, pids, err, errBuf.String())
}

// descendantPids 通过 /proc/<pid>/stat 的 ppid 字段 BFS 收集 root 的全部后代。
func descendantPids(root int) []int {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	children := map[int][]int{}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/stat")
		if err != nil {
			continue
		}
		// stat 格式: pid (comm) state ppid ...；comm 可含空格/括号，取最后一个 ')' 之后
		s := string(b)
		i := strings.LastIndex(s, ")")
		if i < 0 {
			continue
		}
		fields := strings.Fields(s[i+1:])
		if len(fields) < 2 {
			continue
		}
		ppid, err := strconv.Atoi(fields[1]) // fields[0]=state, fields[1]=ppid
		if err != nil {
			continue
		}
		children[ppid] = append(children[ppid], pid)
	}
	var out []int
	queue := []int{root}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for _, c := range children[p] {
			out = append(out, c)
			queue = append(queue, c)
		}
	}
	return out
}

// decodeConsoleOutput Linux 上终端输出已是 UTF-8，无需转码。
func decodeConsoleOutput(b []byte) []byte { return b }
