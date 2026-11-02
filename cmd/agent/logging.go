package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

const (
	defaultLogMaxBytes = 10 * 1024 * 1024
	defaultLogBackups  = 3
)

type rotatingLog struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	backups  int
	file     *os.File
	size     int64
}

func openRotatingLog(path string, maxBytes int64, backups int) (*rotatingLog, error) {
	if path == "" {
		return nil, fmt.Errorf("日志文件路径不能为空")
	}
	if maxBytes <= 0 {
		return nil, fmt.Errorf("日志轮转大小必须大于 0")
	}
	if backups < 0 {
		return nil, fmt.Errorf("日志备份数量不能小于 0")
	}
	if dir := filepath.Dir(path); dir != "." {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return nil, fmt.Errorf("创建日志目录失败: %w", err)
		}
	}
	r := &rotatingLog{path: path, maxBytes: maxBytes, backups: backups}
	if err := r.open(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *rotatingLog) open() error {
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("打开日志文件失败: %w", err)
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return fmt.Errorf("设置日志文件权限失败: %w", err)
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return fmt.Errorf("读取日志文件状态失败: %w", err)
	}
	r.file = f
	r.size = st.Size()
	return nil
}

func (r *rotatingLog) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return 0, fmt.Errorf("日志文件已关闭")
	}
	if r.size > 0 && r.size+int64(len(p)) > r.maxBytes {
		if err := r.rotate(); err != nil {
			return 0, err
		}
	}
	n, err := r.file.Write(p)
	r.size += int64(n)
	return n, err
}

func (r *rotatingLog) rotate() error {
	if err := r.file.Close(); err != nil {
		return fmt.Errorf("关闭日志文件失败: %w", err)
	}
	r.file = nil
	if r.backups == 0 {
		if err := os.Remove(r.path); err != nil && !os.IsNotExist(err) {
			r.open()
			return fmt.Errorf("清理日志文件失败: %w", err)
		}
	} else {
		oldest := fmt.Sprintf("%s.%d", r.path, r.backups)
		if err := os.Remove(oldest); err != nil && !os.IsNotExist(err) {
			r.open()
			return fmt.Errorf("清理旧日志失败: %w", err)
		}
		for i := r.backups - 1; i >= 1; i-- {
			oldPath := fmt.Sprintf("%s.%d", r.path, i)
			newPath := fmt.Sprintf("%s.%d", r.path, i+1)
			if err := os.Rename(oldPath, newPath); err != nil && !os.IsNotExist(err) {
				r.open()
				return fmt.Errorf("轮转旧日志失败: %w", err)
			}
		}
		if err := os.Rename(r.path, r.path+".1"); err != nil && !os.IsNotExist(err) {
			r.open()
			return fmt.Errorf("轮转日志文件失败: %w", err)
		}
	}
	return r.open()
}

func (r *rotatingLog) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return nil
	}
	err := r.file.Close()
	r.file = nil
	return err
}
