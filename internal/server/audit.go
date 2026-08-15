package server

import (
	"fmt"
	"os"
	"sync"
	"time"
)

// Audit 审计日志：记录所有关键操作。
type Audit struct {
	mu sync.Mutex
	f  *os.File
}

// NewAudit 打开（或创建）审计日志文件（0600：命令可能含敏感信息，不对外可读）。
func NewAudit(path string) (*Audit, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return &Audit{f: f}, nil
}

// Logf 写一条带时间戳的审计记录。
func (a *Audit) Logf(format string, args ...any) {
	a.mu.Lock()
	defer a.mu.Unlock()
	fmt.Fprintf(a.f, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}

// Close 关闭日志文件。
func (a *Audit) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.f.Close()
}
