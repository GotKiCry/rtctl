//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// installService Linux：拷贝二进制 + systemd 服务 + 立即启动。
func installService(cfg *installConfig, binPath string) error {
	plan, err := buildLinuxPlan(cfg)
	if err != nil {
		return err
	}
	if *flDryRun {
		return nil
	}
	if os.Geteuid() != 0 {
		return errors.New("需要 root 权限（sudo ./rtctl-wizard ...）")
	}

	// 运行账户（低权限，root 除外）
	if plan.user != "root" {
		if _, err := exec.LookPath("id"); err == nil {
			if err := exec.Command("id", plan.user).Run(); err != nil {
				if err := exec.Command("useradd", "-r", "-s", "/usr/sbin/nologin", plan.user).Run(); err != nil {
					return fmt.Errorf("创建用户 %s 失败: %w", plan.user, err)
				}
			}
		}
	}

	// 安装二进制
	dst := "/usr/local/bin/" + plan.binaryName
	if err := copyFile(binPath, dst); err != nil {
		return fmt.Errorf("安装二进制失败: %w", err)
	}
	if binPath != dst {
		os.Remove(binPath)
	}

	// 配置文件（0600）
	if cfg.component == "server" {
		os.MkdirAll("/etc/rtctl", 0o755)
	}
	if cfg.component == "clientd" {
		os.MkdirAll("/etc/rtctl", 0o755)
		if err := copyFile(cfg.devices, "/etc/rtctl/clientd-devices.json"); err != nil {
			return fmt.Errorf("拷贝设备清单失败: %w", err)
		}
		os.Chmod("/etc/rtctl/clientd-devices.json", 0o600)
	}
	for path, content := range plan.extraFiles {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			return fmt.Errorf("写入 %s 失败: %w", path, err)
		}
	}

	unitPath := "/etc/systemd/system/" + plan.unitName + ".service"
	if err := os.WriteFile(unitPath, []byte(plan.unit), 0o644); err != nil {
		return fmt.Errorf("写入 unit 失败: %w", err)
	}
	for _, c := range [][]string{
		{"systemctl", "daemon-reload"},
		{"systemctl", "enable", "--now", plan.unitName},
	} {
		if out, err := exec.Command(c[0], c[1:]...).CombinedOutput(); err != nil {
			return fmt.Errorf("%s 失败: %v %s", strings.Join(c, " "), err, out)
		}
	}
	if err := exec.Command("systemctl", "is-active", "--quiet", plan.unitName).Run(); err != nil {
		return fmt.Errorf("服务未成功启动，journalctl -u %s 查看原因", plan.unitName)
	}
	printSummary(cfg)
	return nil
}
