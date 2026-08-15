package agent

import "io"

// shellSession 平台相关的交互终端会话抽象。
type shellSession interface {
	Stdin() io.Writer  // 向终端写入（stdin）
	Output() io.Reader // 读取终端输出（stdout+stderr 合并）
	Resize(cols, rows uint16) error
	Wait() error  // 等待进程退出
	Close() error // 关闭会话
}
