//go:build !windows

package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
)

// watchWinch 在终端窗口尺寸变化（SIGWINCH）时回调 onWinch。
func watchWinch(ctx context.Context, onWinch func()) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGWINCH)
	defer signal.Stop(ch)
	for {
		select {
		case <-ch:
			onWinch()
		case <-ctx.Done():
			return
		}
	}
}
