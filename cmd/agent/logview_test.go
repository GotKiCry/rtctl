package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// lockedBuffer 供 follow  goroutine 与断言并发使用的输出缓冲。
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func waitForContains(t *testing.T, out *lockedBuffer, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(out.String(), want) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("等待输出超时，期望包含 %q，实际：\n%s", want, out.String())
}

func TestLastLines(t *testing.T) {
	data := "l1\nl2\nl3\nl4\n"
	if got := lastLines(data, 2); len(got) != 2 || got[0] != "l3" || got[1] != "l4" {
		t.Fatalf("lastLines(data, 2) = %v", got)
	}
	if got := lastLines(data, 100); len(got) != 4 || got[0] != "l1" {
		t.Fatalf("lastLines(data, 100) = %v", got)
	}
	if got := lastLines("", 10); got != nil {
		t.Fatalf("lastLines(空, 10) = %v", got)
	}
	if got := lastLines("\n\n", 10); got != nil {
		t.Fatalf("lastLines(仅换行, 10) = %v", got)
	}
}

func TestSanitizeLogLine(t *testing.T) {
	token := strings.Repeat("a", 64)
	cases := []struct{ name, in, want string }{
		{"64位hex", "token = " + token, "token = <redacted>"},
		{"--token空格", "rtctl --token abc123 exec", "rtctl --token=<redacted> exec"},
		{"--token等号", "rtctl --token=abc123 exec", "rtctl --token=<redacted> exec"},
		{"私钥头", "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN <redacted>-----"},
		{"普通行", "2006/01/02 15:04:05 rtctl-agent 已停止: pid=42", "2006/01/02 15:04:05 rtctl-agent 已停止: pid=42"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sanitizeLogLine(c.in); got != c.want {
				t.Fatalf("sanitizeLogLine(%q) = %q，期望 %q", c.in, got, c.want)
			}
		})
	}
}

func TestRenderLogLineColors(t *testing.T) {
	cases := []struct {
		name      string
		line      string
		wantColor string
		wantSrc   bool // 是否期望来源段青色
	}{
		{"启动", "2026/01/02 15:04:05 rtctl-agent 启动: pid=123 id=n listen=:8443 tls=false allow-sudo=false", ansiGreen, false},
		{"启动失败", "2026/01/02 15:04:05 rtctl-agent 启动失败: 监听 :8443 失败", ansiRed, false},
		{"正常停止", "2026/01/02 15:04:06 rtctl-agent 已停止: pid=123", ansiGreen, false},
		{"监听", "2026/01/02 15:04:05 [agent] 直连模式监听 :8443（ws 路径 /ws）", ansiGreen, false},
		{"exec开始", "2026/01/02 15:04:05 [agent] exec 开始 from=1.2.3.4:5 client=c1 exec=e1: uptime", ansiYellow, true},
		{"exec成功", "2026/01/02 15:04:06 [agent] exec 结束 from=1.2.3.4:5 client=c1 exec=e1: uptime exit=0 errcode=-", ansiGreen, true},
		{"exec非零退出", "2026/01/02 15:04:07 [agent] exec 结束 from=1.2.3.4:5 client=c1 exec=e2: false exit=1 errcode=-", ansiRed, true},
		{"exec超时", "2026/01/02 15:04:08 [agent] exec 结束 from=1.2.3.4:5 client=c1 exec=e3: sleep 99 exit=1 errcode=timeout", ansiRed, true},
		{"errcode优先于exit0", "2026/01/02 15:04:08 [agent] exec 结束 from=1.2.3.4:5 client=c1 exec=e4: x exit=0 errcode=sudo_denied", ansiRed, true},
		{"文件传输完成", "2026/01/02 15:04:09 [agent] file_put 完成 from=1.2.3.4:5 client=c1 id=f1: /tmp/a (3 字节)", ansiMagenta, true},
		{"文件传输失败优先红", "2026/01/02 15:04:10 [agent] file_get 失败 from=1.2.3.4:5 client=c1 id=f2: /tmp/nope (无此文件)", ansiRed, true},
		{"shell会话", "2026/01/02 15:04:11 [agent] shell 打开 from=1.2.3.4:5 client=c1 session=s1", ansiBlue, true},
		{"client接入", "2026/01/02 15:04:12 [agent] 直连 client 接入: 1.2.3.4:5 client=c1", ansiCyan, false},
		// 断开行含 “shell=1”，验证连接事件优先于 shell 分类
		{"client断开", "2026/01/02 15:04:13 [agent] 直连 client 1.2.3.4:5 断开：清理 exec=0 shell=1 上传=0 client=c1", ansiCyan, false},
		{"未知消息", "2026/01/02 15:04:14 [agent] 未知消息类型 from=1.2.3.4:5 client=c1: bogus", ansiRed, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := renderLogLine(c.line, true)
			if !strings.Contains(got, c.wantColor) {
				t.Fatalf("renderLogLine 缺少颜色 %q：%q", c.wantColor, got)
			}
			if !strings.HasPrefix(got, ansiDim) {
				t.Fatalf("时间戳应为暗色开头：%q", got)
			}
			if c.wantSrc && !strings.Contains(got, ansiCyan+"from=") {
				t.Fatalf("来源段应为青色：%q", got)
			}
		})
	}
}

func TestRenderLogLineUnknownNoColor(t *testing.T) {
	line := "2026/01/02 15:04:05 some random message"
	got := renderLogLine(line, true)
	for _, color := range []string{ansiRed, ansiGreen, ansiYellow, ansiBlue, ansiMagenta, ansiCyan} {
		if strings.Contains(got, color) {
			t.Fatalf("未知行不应有着色 %q：%q", color, got)
		}
	}
	if !strings.HasPrefix(got, ansiDim) || !strings.HasSuffix(got, " some random message") {
		t.Fatalf("未知行应只保留暗色时间戳：%q", got)
	}
}

func TestRenderLogLineNoColorPassthrough(t *testing.T) {
	line := "2026/01/02 15:04:05 [agent] exec 结束 from=1.2.3.4:5 client=c1 exec=e1: uptime exit=0 errcode=-"
	if got := renderLogLine(line, false); got != line {
		t.Fatalf("no-color 应原样输出：%q", got)
	}
	withSecret := "2026/01/02 15:04:05 token = " + strings.Repeat("b", 64)
	if got := renderLogLine(withSecret, false); strings.Contains(got, strings.Repeat("b", 64)) {
		t.Fatalf("no-color 仍需脱敏：%q", got)
	}
}

func TestShowLogsTail(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.log")
	var lines []string
	for i := 1; i <= 10; i++ {
		lines = append(lines, "2026/01/02 15:04:05 第 "+strconv.Itoa(i)+" 行")
	}
	content := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	out := &lockedBuffer{}
	if err := showLogs(context.Background(), path, 3, false, false, out); err != nil {
		t.Fatal(err)
	}
	got := out.String()
	if strings.Contains(got, "第 7 行") {
		t.Fatalf("不应包含第 7 行：\n%s", got)
	}
	for _, want := range []string{"第 8 行", "第 9 行", "第 10 行"} {
		if !strings.Contains(got, want) {
			t.Fatalf("缺少 %s：\n%s", want, got)
		}
	}
}

func TestShowLogsMissingFile(t *testing.T) {
	err := showLogs(context.Background(), filepath.Join(t.TempDir(), "nope.log"), 10, false, false, &lockedBuffer{})
	if err == nil || !strings.Contains(err.Error(), "日志文件不存在") {
		t.Fatalf("期望“日志文件不存在”错误，实际：%v", err)
	}
}

func TestShowLogsBadLines(t *testing.T) {
	err := showLogs(context.Background(), "x", 0, false, false, &lockedBuffer{})
	if err == nil || !strings.Contains(err.Error(), "-lines 必须大于 0") {
		t.Fatalf("期望 -lines 错误，实际：%v", err)
	}
}

func TestShowLogsFollowAppend(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.log")
	if err := os.WriteFile(path, []byte("2026/01/02 15:04:05 初始行\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &lockedBuffer{}
	done := make(chan error, 1)
	go func() { done <- showLogs(ctx, path, 100, true, false, out) }()
	waitForContains(t, out, "初始行")

	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("2026/01/02 15:04:06 新增行\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	waitForContains(t, out, "新增行")

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("follow 退出报错：%v", err)
	}
}

func TestShowLogsFollowPartialLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.log")
	if err := os.WriteFile(path, []byte("2026/01/02 15:04:05 初始行\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &lockedBuffer{}
	done := make(chan error, 1)
	go func() { done <- showLogs(ctx, path, 100, true, false, out) }()
	waitForContains(t, out, "初始行")

	// 写入不带换行的残行：不应提前输出
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("2026/01/02 15:04:06 残行尚未完成"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	time.Sleep(600 * time.Millisecond)
	if strings.Contains(out.String(), "残行尚未完成") {
		t.Fatalf("半行不应提前输出：\n%s", out.String())
	}

	f, err = os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("，现在完成\n"); err != nil {
		t.Fatal(err)
	}
	f.Close()
	waitForContains(t, out, "残行尚未完成，现在完成")

	cancel()
	<-done
}

func TestShowLogsFollowRotation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.log")
	if err := os.WriteFile(path, []byte("2026/01/02 15:04:05 轮转前\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &lockedBuffer{}
	done := make(chan error, 1)
	go func() { done <- showLogs(ctx, path, 100, true, false, out) }()
	waitForContains(t, out, "轮转前")

	// 模拟轮转：旧文件改名，新建同名文件。
	// Windows 上 follower 可能正打开旧文件轮询，rename 可能瞬时失败，重试几次。
	var renErr error
	for i := 0; i < 20; i++ {
		if renErr = os.Rename(path, path+".1"); renErr == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if renErr != nil {
		t.Fatal(renErr)
	}
	if err := os.WriteFile(path, []byte("2026/01/02 15:04:06 轮转后新行\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForContains(t, out, "轮转后新行")

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("follow 退出报错：%v", err)
	}
}
