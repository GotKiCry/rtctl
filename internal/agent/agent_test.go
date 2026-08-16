package agent

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"rtctl/internal/proto"
)

// fakeSink 收集所有发出消息的 sendSink 测试桩。
type fakeSink struct {
	mu   sync.Mutex
	msgs []proto.Msg
}

func (f *fakeSink) Send(m proto.Msg) error {
	f.mu.Lock()
	f.msgs = append(f.msgs, m)
	f.mu.Unlock()
	return nil
}

func (f *fakeSink) SendBlocking(m proto.Msg, _ time.Duration) error { return f.Send(m) }

func (f *fakeSink) CloseConn() {}

func (f *fakeSink) snapshot() []proto.Msg {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]proto.Msg, len(f.msgs))
	copy(out, f.msgs)
	return out
}

// TestExecIDConflictRejected 重复的 exec ID 必须被拒绝（契约 6.4 的 conflict），
// 且命令不得执行、注册表项不得被覆盖。
func TestExecIDConflictRejected(t *testing.T) {
	a := New("dev", "tok")
	a.execs["dup"] = func() {}

	m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeExec, ID: "dup"},
		proto.ExecPayload{Cmd: "echo SHOULD-NOT-RUN"})
	sink := &fakeSink{}
	a.handleExec(m, sink) // 同步返回（冲突在启动进程前拒绝）

	var done *proto.ExecOutputPayload
	var all strings.Builder
	for _, msg := range sink.snapshot() {
		if msg.Type != proto.TypeExecOutput {
			continue
		}
		var p proto.ExecOutputPayload
		if err := msg.PayloadOf(&p); err != nil {
			t.Fatal(err)
		}
		all.WriteString(p.Data)
		if p.Done {
			pp := p
			done = &pp
		}
	}
	if done == nil {
		t.Fatal("没有 done 帧")
	}
	if done.ErrorCode != proto.ErrorCodeConflict {
		t.Errorf("错误码应为 conflict，实际 %q（%s）", done.ErrorCode, done.Error)
	}
	if strings.Contains(all.String(), "SHOULD-NOT-RUN") {
		t.Error("冲突命令被执行了")
	}
	if len(a.execs) != 1 {
		t.Errorf("注册表被改动: %d 项", len(a.execs))
	}
}

// shellAck 从 sink 里找 shell_ack。
func shellAck(t *testing.T, sink *fakeSink) (bool, string, string) {
	t.Helper()
	for _, msg := range sink.snapshot() {
		if msg.Type != proto.TypeShellAck {
			continue
		}
		var p proto.ShellAckPayload
		if err := msg.PayloadOf(&p); err != nil {
			t.Fatal(err)
		}
		return p.OK, msg.SessionID, p.Error
	}
	t.Fatal("没有 shell_ack")
	return false, "", ""
}

func openShell(a *Agent, sid string) *fakeSink {
	sink := &fakeSink{}
	a.handleShellOpen(proto.Msg{Type: proto.TypeShellOpen, SessionID: sid}, sink)
	return sink
}

// closeAllShells 关闭所有会话并等待注册表与并发闸归零。
func closeAllShells(t *testing.T, a *Agent) {
	t.Helper()
	a.mu.Lock()
	sids := make([]string, 0, len(a.shells))
	for sid := range a.shells {
		sids = append(sids, sid)
	}
	a.mu.Unlock()
	for _, sid := range sids {
		a.handleShellCtrl(proto.Msg{Type: proto.TypeShellClose, SessionID: sid})
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		a.mu.Lock()
		n := len(a.shells)
		a.mu.Unlock()
		if n == 0 && len(a.shellSem) == 0 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	t.Fatalf("会话未全部退出: shells=%d sem=%d/%d", len(a.shells), len(a.shellSem), maxConcurrentShell)
}

// TestShellOpenGeneratesSessionID 空会话 ID（旧客户端）由 agent 兜底生成。
func TestShellOpenGeneratesSessionID(t *testing.T) {
	a := New("dev", "tok")
	sink := openShell(a, "")
	ok, sid, errStr := shellAck(t, sink)
	if !ok {
		t.Skipf("本机无法创建 shell 会话，跳过: %s", errStr)
	}
	defer closeAllShells(t, a)
	if sid == "" {
		t.Error("agent 应为空会话 ID 生成随机 ID")
	}
	a.mu.Lock()
	_, registered := a.shells[sid]
	a.mu.Unlock()
	if !registered {
		t.Errorf("会话未按生成的 ID 注册: %q", sid)
	}
}

// TestShellConcurrencyLimitHeldForSession 并发闸必须持有到会话结束：
// 开满 maxConcurrentShell 个会话后第 N+1 个被拒；关掉一个后应能再开。
// （修复前 defer 在 handleShellOpen 返回时就释放，上限形同虚设。）
func TestShellConcurrencyLimitHeldForSession(t *testing.T) {
	a := New("dev", "tok")
	first := openShell(a, "s-0")
	if ok, _, errStr := shellAck(t, first); !ok {
		t.Skipf("本机无法创建 shell 会话，跳过: %s", errStr)
	}
	defer closeAllShells(t, a)

	for i := 1; i < maxConcurrentShell; i++ {
		sink := openShell(a, fmt.Sprintf("s-%d", i))
		if ok, _, errStr := shellAck(t, sink); !ok {
			t.Fatalf("第 %d 个会话应打开成功: %s", i+1, errStr)
		}
	}
	over := openShell(a, "s-over")
	if ok, _, errStr := shellAck(t, over); ok {
		t.Error("超过并发上限的 shell 应被拒绝")
	} else if !strings.Contains(errStr, "超限") {
		t.Errorf("拒绝原因应为超限，实际 %q", errStr)
	}

	// 关掉一个 → 闸位释放 → 能再开
	a.handleShellCtrl(proto.Msg{Type: proto.TypeShellClose, SessionID: "s-0"})
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) && len(a.shellSem) == maxConcurrentShell {
		time.Sleep(50 * time.Millisecond)
	}
	again := openShell(a, "s-again")
	if ok, _, errStr := shellAck(t, again); !ok {
		t.Errorf("释放一个会话后应能再开: %s", errStr)
	}
}

// TestShellSessionIDConflict 相同会话 ID 的第二次 shell_open 必须被拒绝，
// 且不得顶掉原会话。
func TestShellSessionIDConflict(t *testing.T) {
	a := New("dev", "tok")
	first := openShell(a, "dup-sid")
	if ok, _, errStr := shellAck(t, first); !ok {
		t.Skipf("本机无法创建 shell 会话，跳过: %s", errStr)
	}
	defer closeAllShells(t, a)

	second := openShell(a, "dup-sid")
	if ok, _, errStr := shellAck(t, second); ok {
		t.Error("重复会话 ID 应被拒绝")
	} else if !strings.Contains(errStr, proto.ErrorCodeConflict) {
		t.Errorf("拒绝原因应含 conflict，实际 %q", errStr)
	}
	a.mu.Lock()
	_, alive := a.shells["dup-sid"]
	n := len(a.shells)
	a.mu.Unlock()
	if !alive || n != 1 {
		t.Errorf("原会话不应被顶替: alive=%v n=%d", alive, n)
	}
}

// TestFilePutIDConflict 相同传输 ID 的第二次 file_put 必须被拒绝。
func TestFilePutIDConflict(t *testing.T) {
	a := New("dev", "tok")
	dir := t.TempDir()
	mk := func() (*fakeSink, proto.Msg) {
		sink := &fakeSink{}
		m, _ := proto.WithPayload(proto.Msg{Type: proto.TypeFilePut, ID: "dup-put"},
			proto.FilePutPayload{Path: dir + "/f.bin", Size: 4})
		return sink, m
	}
	s1, m1 := mk()
	a.handleFilePut(m1, s1)
	s2, m2 := mk()
	a.handleFilePut(m2, s2)

	ackOf := func(s *fakeSink) (bool, string) {
		for _, msg := range s.snapshot() {
			if msg.Type != proto.TypeFilePutAck {
				continue
			}
			var p proto.FilePutAckPayload
			if err := msg.PayloadOf(&p); err != nil {
				t.Fatal(err)
			}
			return p.OK, p.Error
		}
		return false, "(无 ack)"
	}
	// 第一次 put 建立中（无 ack 属正常，分片未到）；第二次必须冲突拒绝
	ok2, err2 := ackOf(s2)
	if ok2 || !strings.Contains(err2, proto.ErrorCodeConflict) {
		t.Errorf("第二次 file_put 应冲突拒绝: ok=%v err=%q", ok2, err2)
	}
	a.handleFileAbort(proto.Msg{Type: proto.TypeFileAbort, ID: "dup-put"})
}
