//go:build windows

package main

import "context"

// watchWinch Windows 无 SIGWINCH，窗口变化无法感知，初始尺寸已足够。
func watchWinch(ctx context.Context, onWinch func()) {
	<-ctx.Done()
}
