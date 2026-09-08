//go:build linux

package agent

import "syscall"

// shellExecArgs Linux：/bin/sh -c；Setpgid 让子进程成为进程组长，
// 便于超时/取消时 killProcessTree 整组终止（覆盖孙进程）。
// sudo=true（且已被 -allow-sudo 授权）时经 sudo 提权执行：
//   - sudoPw 为空：`sudo -n`（依赖 sudoers NOPASSWD，永久授权）
//   - sudoPw 非空：`sudo -S -p ''`（从 stdin 首行读密码，临时授权）
func shellExecArgs(cmd string, sudo bool, sudoPw string) ([]string, *syscall.SysProcAttr) {
	if sudo {
		if sudoPw != "" {
			return []string{"sudo", "-S", "-p", "", "--", "/bin/sh", "-c", cmd}, &syscall.SysProcAttr{Setpgid: true}
		}
		return []string{"sudo", "-n", "--", "/bin/sh", "-c", cmd}, &syscall.SysProcAttr{Setpgid: true}
	}
	return []string{"/bin/sh", "-c", cmd}, &syscall.SysProcAttr{Setpgid: true}
}
