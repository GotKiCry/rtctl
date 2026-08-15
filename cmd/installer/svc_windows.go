//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// installService Windows：拷贝二进制 + 计划任务 + 立即运行。
func installService(cfg *installConfig, binPath string) error {
	installDir := `C:\Program Files\rtctl`
	plan, err := buildWinPlan(cfg, installDir)
	if err != nil {
		return err
	}
	if *flDryRun {
		return nil
	}
	if err := os.MkdirAll(installDir, 0o755); err != nil {
		return fmt.Errorf("无法创建安装目录 %s（需管理员权限）: %w", installDir, err)
	}
	dst := filepath.Join(installDir, plan.exeName)
	if err := copyFile(binPath, dst); err != nil {
		return fmt.Errorf("安装二进制失败: %w", err)
	}
	if binPath != dst {
		os.Remove(binPath)
	}
	for path, content := range plan.extra {
		if path == "__env_token__" {
			continue
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			return fmt.Errorf("写入 %s 失败: %w", path, err)
		}
	}
	xmlBytes, err := buildTaskXML(cfg, dst, plan.args)
	if err != nil {
		return err
	}
	xmlPath := filepath.Join(os.TempDir(), plan.taskName+".xml")
	if err := os.WriteFile(xmlPath, xmlBytes, 0o600); err != nil {
		return err
	}
	defer os.Remove(xmlPath)

	if out, err := exec.Command("schtasks", "/Create", "/TN", plan.taskName, "/XML", xmlPath, "/F").CombinedOutput(); err != nil {
		return fmt.Errorf("注册计划任务失败（需管理员权限）: %v %s", err, out)
	}
	if out, err := exec.Command("schtasks", "/Run", "/TN", plan.taskName).CombinedOutput(); err != nil {
		return fmt.Errorf("启动任务失败: %v %s", err, out)
	}
	printSummary(cfg)
	return nil
}

// uninstallService Windows：卸载组件（删计划任务、删二进制与配置）。
func uninstallService(comp string) error {
	installDir := `C:\Program Files\rtctl`
	if comp == "" {
		comp = "all"
	}
	for _, c := range []string{"agent", "clientd"} {
		if comp != "all" && comp != c {
			continue
		}
		exec.Command("schtasks", "/Delete", "/TN", "rtctl-"+c, "/F").Run()
		switch c {
		case "agent":
			os.Remove(filepath.Join(installDir, "rtctl-agent.exe"))
		case "clientd":
			os.Remove(filepath.Join(installDir, "rtctl-client.exe"))
			os.Remove(filepath.Join(installDir, "clientd-devices.json"))
		}
		fmt.Printf("✔ %s 已卸载\n", c)
	}
	return nil
}
