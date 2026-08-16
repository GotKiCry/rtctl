//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"strconv"
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

	// 安装二进制（先停旧服务，避免覆盖运行中的可执行文件报 text file busy）
	exec.Command("systemctl", "stop", plan.unitName).Run()
	dst := "/usr/local/bin/" + plan.binaryName
	if err := copyFile(binPath, dst); err != nil {
		return fmt.Errorf("安装二进制失败: %w", err)
	}
	if binPath != dst {
		os.Remove(binPath)
	}

	// 配置文件（0600 且归属服务运行账户——否则服务读不到会崩溃循环）
	chownTo := func(path string) error {
		u, err := user.Lookup(plan.user)
		if err != nil {
			return fmt.Errorf("查找用户 %s 失败: %w", plan.user, err)
		}
		uid, _ := strconv.Atoi(u.Uid)
		gid, _ := strconv.Atoi(u.Gid)
		return os.Chown(path, uid, gid)
	}
	if cfg.component == "clientd" {
		os.MkdirAll("/etc/rtctl", 0o755)
		if err := copyFile(cfg.devices, "/etc/rtctl/clientd-devices.json"); err != nil {
			return fmt.Errorf("拷贝设备清单失败: %w", err)
		}
		os.Chmod("/etc/rtctl/clientd-devices.json", 0o600)
		if err := chownTo("/etc/rtctl/clientd-devices.json"); err != nil {
			return fmt.Errorf("授权设备清单失败: %w", err)
		}
	}
	for path, content := range plan.extraFiles {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			return fmt.Errorf("写入 %s 失败: %w", path, err)
		}
		if err := chownTo(path); err != nil {
			return fmt.Errorf("授权 %s 失败: %w", path, err)
		}
	}

	// sudoers 放行（root:root 0440，visudo 校验；不授权时移除旧文件）
	sudoersPath := "/etc/sudoers.d/rtctl-agent"
	if plan.sudoers != "" {
		if err := os.WriteFile(sudoersPath, []byte(plan.sudoers), 0o440); err != nil {
			return fmt.Errorf("写入 %s 失败: %w", sudoersPath, err)
		}
		if out, err := exec.Command("visudo", "-c", "-f", sudoersPath).CombinedOutput(); err != nil {
			os.Remove(sudoersPath)
			return fmt.Errorf("sudoers 校验失败: %v %s", err, out)
		}
	} else if cfg.component == "agent" {
		os.Remove(sudoersPath) // 重装为不授权：清掉旧放行
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

// uninstallService Linux：卸载组件（停止服务、删 unit、删二进制与配置）。
func uninstallService(comp string) error {
	if comp == "" {
		comp = "all"
	}
	for _, c := range []string{"agent", "clientd"} {
		if comp != "all" && comp != c {
			continue
		}
		unit := "rtctl-" + c
		exec.Command("systemctl", "disable", "--now", unit).Run()
		os.Remove("/etc/systemd/system/" + unit + ".service")
		switch c {
		case "agent":
			os.Remove("/usr/local/bin/rtctl-agent")
			os.Remove("/etc/rtctl/agent.token")
			os.Remove("/etc/sudoers.d/rtctl-agent")
		case "clientd":
			os.Remove("/usr/local/bin/rtctl-client")
			os.Remove("/etc/rtctl/clientd-devices.json")
		}
		fmt.Printf("✔ %s 已卸载\n", c)
	}
	exec.Command("systemctl", "daemon-reload").Run()
	return nil
}
