package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
)

// ANSI 颜色。只用于 -logs 的终端渲染，绝不写入日志文件。
const (
	ansiReset   = "\x1b[0m"
	ansiDim     = "\x1b[2m"
	ansiRed     = "\x1b[31m"
	ansiGreen   = "\x1b[32m"
	ansiYellow  = "\x1b[33m"
	ansiBlue    = "\x1b[34m"
	ansiMagenta = "\x1b[35m"
	ansiCyan    = "\x1b[36m"
)

var (
	reLogTimestamp = regexp.MustCompile(`^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}`)
	reLogSource    = regexp.MustCompile(`from=\S+ client=\S+`)
	reLogExit      = regexp.MustCompile(`\bexit=(\d+)`)
	reLogErrCode   = regexp.MustCompile(`\berrcode=(\S+)`)
	reLogHex64     = regexp.MustCompile(`[0-9a-fA-F]{64}`)
	reLogTokenArg  = regexp.MustCompile(`--token[= ]\S*`)
	reLogPrivKey   = regexp.MustCompile(`BEGIN [A-Z ]*PRIVATE KEY`)
)

// sanitizeLogLine 对日志行做最小脱敏（与 install.sh sanitize_text 对齐），
// 保证程序内查看不会泄露 token / 私钥。
func sanitizeLogLine(line string) string {
	line = reLogHex64.ReplaceAllString(line, "<redacted>")
	line = reLogTokenArg.ReplaceAllString(line, "--token=<redacted>")
	line = reLogPrivKey.ReplaceAllString(line, "BEGIN <redacted>")
	return line
}

// classifyLogLine 按事件类别给日志主体定色：
// 红=失败/非零退出/超时，黄=命令开始，品红=文件传输，蓝=shell 会话，
// 青=client 接入/断开，绿=启动/监听/成功完成，空=默认色。
func classifyLogLine(body string) string {
	for _, kw := range []string{"启动失败", "失败", "超时", "未知消息", "取消"} {
		if strings.Contains(body, kw) {
			return ansiRed
		}
	}
	if m := reLogErrCode.FindStringSubmatch(body); m != nil && m[1] != "-" {
		return ansiRed
	}
	if m := reLogExit.FindStringSubmatch(body); m != nil {
		if m[1] != "0" {
			return ansiRed
		}
		return ansiGreen
	}
	if strings.Contains(body, "exec 开始") {
		return ansiYellow
	}
	if strings.Contains(body, "file_put") || strings.Contains(body, "file_get") {
		return ansiMagenta
	}
	if strings.Contains(body, "client 接入") || strings.Contains(body, "断开") {
		return ansiCyan
	}
	if strings.Contains(body, "shell") {
		return ansiBlue
	}
	for _, kw := range []string{"启动", "已停止", "监听", "完成"} {
		if strings.Contains(body, kw) {
			return ansiGreen
		}
	}
	return ""
}

// renderLogLine 渲染一行日志：先脱敏，再按需着色。
// 时间戳用暗色，来源段 from=... client=... 用青色，主体按 classifyLogLine 定色。
func renderLogLine(line string, color bool) string {
	line = sanitizeLogLine(line)
	if !color {
		return line
	}
	ts := reLogTimestamp.FindString(line)
	body := line[len(ts):]
	bodyColor := classifyLogLine(body)
	if src := reLogSource.FindString(body); src != "" {
		body = strings.Replace(body, src, ansiReset+ansiCyan+src+ansiReset+bodyColor, 1)
	}
	var b strings.Builder
	if ts != "" {
		b.WriteString(ansiDim + ts + ansiReset)
	}
	b.WriteString(bodyColor)
	b.WriteString(body)
	if bodyColor != "" {
		b.WriteString(ansiReset)
	}
	return b.String()
}

// showLogs 输出日志文件的最后 lines 行；follow=true 时继续跟随新增内容，
// 直到 ctx 取消（Ctrl+C / SIGTERM）。
func showLogs(ctx context.Context, path string, lines int, follow bool, color bool, out io.Writer) error {
	if lines <= 0 {
		return fmt.Errorf("-lines 必须大于 0")
	}
	data, info, err := readLogFile(path)
	if err != nil {
		return err
	}
	for _, line := range lastLines(string(data), lines) {
		fmt.Fprintln(out, renderLogLine(line, color))
	}
	if !follow {
		return nil
	}
	return followLog(ctx, path, int64(len(data)), info, out, color)
}

func readLogFile(path string) ([]byte, os.FileInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil, fmt.Errorf("日志文件不存在: %s（agent 可能还未运行过；可用 -log-file 指定路径）", path)
		}
		return nil, nil, fmt.Errorf("打开日志文件失败: %w", err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, nil, fmt.Errorf("读取日志文件状态失败: %w", err)
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, nil, fmt.Errorf("读取日志文件失败: %w", err)
	}
	return data, info, nil
}

// lastLines 取文本的最后 n 行（忽略末尾空行）。
func lastLines(data string, n int) []string {
	data = strings.TrimRight(data, "\n")
	if data == "" {
		return nil
	}
	lines := strings.Split(data, "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return lines
}

// followLog 从 offset 开始轮询追加内容：
// 用文件身份（os.SameFile）而非 size 判断轮转——新文件可能比旧 offset 更长；
// 文件短暂不存在（轮转瞬间）等待重建；截断/换新则从头重读；
// 半行写入先缓冲、遇换行才输出。
func followLog(ctx context.Context, path string, offset int64, info os.FileInfo, out io.Writer, color bool) error {
	var pending []byte
	for {
		st, err := os.Stat(path)
		if err != nil {
			if os.IsNotExist(err) {
				if err := sleepOrDone(ctx); err != nil {
					return nil
				}
				continue
			}
			return fmt.Errorf("读取日志文件状态失败: %w", err)
		}
		if info == nil || !os.SameFile(info, st) || st.Size() < offset {
			// 轮转出同名新文件，或文件被截断：从头读
			offset = 0
			pending = pending[:0]
		}
		info = st
		if st.Size() > offset {
			n, err := drainLogRange(path, offset, out, &pending, color)
			offset += n
			if err != nil {
				if os.IsNotExist(err) {
					continue
				}
				return err
			}
		}
		if err := sleepOrDone(ctx); err != nil {
			return nil
		}
	}
}

// drainLogRange 打开 path 并从 offset 读到文件尾，返回实际读取的字节数。
func drainLogRange(path string, offset int64, out io.Writer, pending *[]byte, color bool) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, fmt.Errorf("打开日志文件失败: %w", err)
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return 0, fmt.Errorf("定位日志文件失败: %w", err)
	}
	n, err := drainAppended(f, out, pending, color)
	if err != nil {
		return n, fmt.Errorf("读取日志文件失败: %w", err)
	}
	return n, nil
}

func sleepOrDone(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(250 * time.Millisecond):
		return nil
	}
}

// drainAppended 读完 r 当前可用内容，返回读取字节数；
// 只有完整行（以 \n 结尾）才渲染输出，残行留在 pending 等待下次拼接。
func drainAppended(r io.Reader, out io.Writer, pending *[]byte, color bool) (int64, error) {
	var total int64
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			total += int64(n)
			*pending = append(*pending, buf[:n]...)
			for {
				i := bytes.IndexByte(*pending, '\n')
				if i < 0 {
					break
				}
				line := string((*pending)[:i])
				*pending = (*pending)[i+1:]
				fmt.Fprintln(out, renderLogLine(line, color))
			}
		}
		if err == io.EOF {
			return total, nil
		}
		if err != nil {
			return total, err
		}
	}
}

// wantColor 汇总颜色开关：-no-color / NO_COLOR / 非终端输出 都会降级为纯文本，
// Windows 下还需成功启用 Virtual Terminal Processing。
func wantColor(noColorFlag bool) bool {
	if noColorFlag {
		return false
	}
	if _, ok := os.LookupEnv("NO_COLOR"); ok {
		return false
	}
	st, err := os.Stdout.Stat()
	if err != nil || st.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	return enableANSI()
}
