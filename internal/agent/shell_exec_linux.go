//go:build linux

package agent

import "syscall"

// shellExecArgs Linux：/bin/sh -c；Setpgid 让子进程成为进程组长，
// 便于超时/取消时 killProcessTree 整组终止（覆盖孙进程）。
func shellExecArgs(cmd string) ([]string, *syscall.SysProcAttr) {
	return []string{"/bin/sh", "-c", cmd}, &syscall.SysProcAttr{Setpgid: true}
}
