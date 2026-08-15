//go:build windows

package agent

import (
	"io"
	"os/exec"
	"strconv"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

// pipeSession Windows 上的 cmd 管道模式（非真 PTY，普通命令完全可用）。
type pipeSession struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	output io.Reader
	done   chan struct{}
}

func newShellSession() (shellSession, error) {
	cmd := exec.Command("cmd.exe")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	// stdout 与 stderr 并发拷贝合并：串行拷贝会在对端管道写满时死锁子进程
	pr, pw := io.Pipe()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(pw, stdout) }()
	go func() { defer wg.Done(); io.Copy(pw, stderr) }()
	go func() { wg.Wait(); pw.Close() }()
	done := make(chan struct{})
	go func() {
		cmd.Wait()
		close(done)
	}()
	return &pipeSession{cmd: cmd, stdin: stdin, output: pr, done: done}, nil
}

func (s *pipeSession) Stdin() io.Writer { return s.stdin }

func (s *pipeSession) Output() io.Reader { return s.output }

func (s *pipeSession) Resize(cols, rows uint16) error { return nil } // 管道模式不支持

func (s *pipeSession) Wait() error { <-s.done; return nil }

// Close 优雅关闭：写入 exit 让 cmd 处理完缓冲输入后自然退出，最多等 2 秒再强杀。
func (s *pipeSession) Close() error {
	s.stdin.Write([]byte("exit\r\n"))
	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
	}
	s.stdin.Close()
	if s.cmd.Process != nil {
		s.cmd.Process.Kill()
	}
	return nil
}

// killProcessTree Windows 上终止整个进程树：
// TerminateProcess 只杀直接子进程，孙进程会存活并继续持有输出管道，
// 因此用 taskkill /T 级联终止。
func killProcessTree(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	tk := exec.Command("taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F")
	tk.Stdout = io.Discard
	tk.Stderr = io.Discard
	_ = tk.Run()
}

// decodeConsoleOutput 把 Windows 控制台输出转换为 UTF-8。
// 启发式：已是合法 UTF-8 则原样返回（现代程序），否则按 GBK/CP936 解码
// （中文系统 cmd 默认代码页）。分片边界切开多字节字符时回退原样，宁可不转不损坏。
func decodeConsoleOutput(b []byte) []byte {
	if utf8.Valid(b) {
		return b
	}
	out, err := simplifiedchinese.GBK.NewDecoder().Bytes(b)
	if err != nil {
		return b
	}
	return out
}
