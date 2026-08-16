//go:build linux

package agent

import "syscall"

// shellExecArgs Linux：/bin/sh -c；Setpgid 让子进程成为进程组长，
// 便于超时/取消时 killProcessTree 整组终止（覆盖孙进程）。
// sudo=true（且已被 -allow-sudo 授权）时经 sudo -n 提权执行：
// sudoers 按命令路径放行 /bin/sh，无需密码（NOPASSWD）。
func shellExecArgs(cmd string, sudo bool) ([]string, *syscall.SysProcAttr) {
	if sudo {
		return []string{"sudo", "-n", "--", "/bin/sh", "-c", cmd}, &syscall.SysProcAttr{Setpgid: true}
	}
	return []string{"/bin/sh", "-c", cmd}, &syscall.SysProcAttr{Setpgid: true}
}
