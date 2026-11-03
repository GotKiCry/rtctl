//go:build windows

package agent

import (
	"io"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/windows"

	"rtctl/internal/proto"
)

const windowsChildCommand = `powershell -NoProfile -Command "Write-Output ('RTCTL-CHILD-' + $PID); Start-Sleep -Seconds 60"`

type windowsLockedOutput struct {
	mu   sync.Mutex
	data strings.Builder
}

func (b *windowsLockedOutput) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.Write(p)
}

func (b *windowsLockedOutput) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.String()
}

func windowsChildPID(output string) (int, bool) {
	const marker = "RTCTL-CHILD-"
	index := strings.LastIndex(output, marker)
	if index < 0 {
		return 0, false
	}
	rest := output[index+len(marker):]
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
		end++
	}
	if end == 0 {
		return 0, false
	}
	pid, err := strconv.Atoi(rest[:end])
	return pid, err == nil && pid > 0
}

func waitWindowsChildPID(t *testing.T, output func() string) int {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if pid, ok := windowsChildPID(output()); ok {
			t.Cleanup(func() {
				handle, err := windows.OpenProcess(windows.PROCESS_TERMINATE, false, uint32(pid))
				if err == nil {
					_ = windows.TerminateProcess(handle, 1)
					_ = windows.CloseHandle(handle)
				}
			})
			return pid
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("没有收到子进程 PID，输出：%q", output())
	return 0
}

func waitWindowsProcessExit(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
		if err != nil {
			return
		}
		var exitCode uint32
		err = windows.GetExitCodeProcess(handle, &exitCode)
		windows.CloseHandle(handle)
		if err != nil || exitCode != 259 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("子进程仍在运行: pid=%d", pid)
}

func startWindowsExec(a *Agent, sink *fakeSink, id, command string, timeoutMS int) chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExec, ID: id},
			proto.ExecPayload{Cmd: command, TimeoutMS: timeoutMS})
		a.handleExec(m, sink)
	}()
	return done
}

func waitWindowsExecResult(t *testing.T, sink *fakeSink, done chan struct{}) (string, proto.ExecOutputPayload) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(8 * time.Second):
		t.Fatal("exec 未在限定时间内结束")
	}
	var output strings.Builder
	var final *proto.ExecOutputPayload
	for _, msg := range sink.snapshot() {
		if msg.Type != proto.TypeExecOutput {
			continue
		}
		var p proto.ExecOutputPayload
		if err := msg.PayloadOf(&p); err != nil {
			t.Fatal(err)
		}
		output.WriteString(p.Data)
		if p.Done {
			copy := p
			final = &copy
		}
	}
	if final == nil {
		t.Fatal("没有 done 帧")
	}
	return output.String(), *final
}

func windowsExecOutput(sink *fakeSink) string {
	var output strings.Builder
	for _, msg := range sink.snapshot() {
		if msg.Type != proto.TypeExecOutput {
			continue
		}
		var p proto.ExecOutputPayload
		if msg.PayloadOf(&p) == nil {
			output.WriteString(p.Data)
		}
	}
	return output.String()
}

func TestWindowsExecNormalCompletion(t *testing.T) {
	a := New("dev", "tok")
	sink := &fakeSink{}
	done := startWindowsExec(a, sink, "normal", "echo normal-ok", 0)
	output, result := waitWindowsExecResult(t, sink, done)
	if result.ExitCode != 0 || result.ErrorCode != "" || !strings.Contains(output, "normal-ok") {
		t.Fatalf("正常执行结果异常: output=%q result=%+v", output, result)
	}
}

func TestWindowsExecTimeoutKillsChildProcess(t *testing.T) {
	a := New("dev", "tok")
	sink := &fakeSink{}
	done := startWindowsExec(a, sink, "timeout", windowsChildCommand, 1500)
	pid := waitWindowsChildPID(t, func() string { return windowsExecOutput(sink) })
	_, result := waitWindowsExecResult(t, sink, done)
	if result.ErrorCode != proto.ErrorCodeTimeout {
		t.Fatalf("错误码应为 timeout，实际 %+v", result)
	}
	waitWindowsProcessExit(t, pid)
}

func TestWindowsExecTimeoutKillsChildAfterRootExit(t *testing.T) {
	a := New("dev", "tok")
	sink := &fakeSink{}
	done := startWindowsExec(a, sink, "root-exited", `start "" /B `+windowsChildCommand, 1500)
	pid := waitWindowsChildPID(t, func() string { return windowsExecOutput(sink) })
	_, result := waitWindowsExecResult(t, sink, done)
	if result.ErrorCode != proto.ErrorCodeTimeout {
		t.Fatalf("错误码应为 timeout，实际 %+v", result)
	}
	waitWindowsProcessExit(t, pid)
}

func TestWindowsExecKillKillsChildProcess(t *testing.T) {
	a := New("dev", "tok")
	sink := &fakeSink{}
	done := startWindowsExec(a, sink, "kill", windowsChildCommand, 0)
	pid := waitWindowsChildPID(t, func() string { return windowsExecOutput(sink) })
	m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExecKill}, proto.ExecKillPayload{ExecID: "kill"})
	a.handleExecKill(m, sink)
	_, result := waitWindowsExecResult(t, sink, done)
	if result.ErrorCode != proto.ErrorCodeKilled {
		t.Fatalf("错误码应为 killed，实际 %+v", result)
	}
	waitWindowsProcessExit(t, pid)
}

func TestWindowsShellCloseKillsChildProcess(t *testing.T) {
	sess, err := newShellSession()
	if err != nil {
		t.Fatal(err)
	}
	var output windowsLockedOutput
	go io.Copy(&output, sess.Output())
	if _, err := sess.Stdin().Write([]byte(windowsChildCommand + "\r\n")); err != nil {
		t.Fatal(err)
	}
	pid := waitWindowsChildPID(t, output.String)
	closed := make(chan error, 1)
	go func() { closed <- sess.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("shell 未在限定时间内关闭")
	}
	waitWindowsProcessExit(t, pid)
}
