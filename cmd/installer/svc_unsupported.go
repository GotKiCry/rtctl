//go:build !linux && !windows

package main

import "errors"

func installService(cfg *installConfig, binPath string) error {
	return errors.New("仅支持 Linux 与 Windows")
}
