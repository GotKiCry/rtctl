//go:build windows

package agent

import (
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

type windowsExecProcess struct {
	mu  sync.Mutex
	job windows.Handle
}

func startExecProcess(cmd *exec.Cmd, _ bool) (execProcess, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, fmt.Errorf("创建 Job Object 失败: %w", err)
	}
	process := &windowsExecProcess{job: job}
	fail := func(startErr error) (execProcess, error) {
		if cmd.Process != nil {
			_ = windows.TerminateJobObject(job, 1)
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
		_ = windows.CloseHandle(job)
		return nil, startErr
	}

	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.CreationFlags |= windows.CREATE_SUSPENDED
	if err := cmd.Start(); err != nil {
		return fail(err)
	}

	// 根进程恢复运行前加入 Job，保证它创建的普通子进程也从属于同一 Job。
	root, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err != nil {
		return fail(fmt.Errorf("打开命令进程失败: %w", err))
	}
	err = windows.AssignProcessToJobObject(job, root)
	windows.CloseHandle(root)
	if err != nil {
		return fail(fmt.Errorf("将命令加入 Job Object 失败: %w", err))
	}
	if err := resumeProcessMainThread(uint32(cmd.Process.Pid)); err != nil {
		return fail(fmt.Errorf("恢复命令进程失败: %w", err))
	}
	return process, nil
}

func resumeProcessMainThread(pid uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)

	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	if err := windows.Thread32First(snapshot, &entry); err != nil {
		return err
	}
	for {
		if entry.OwnerProcessID == pid {
			thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
			if err != nil {
				return err
			}
			_, err = windows.ResumeThread(thread)
			windows.CloseHandle(thread)
			return err
		}
		if err := windows.Thread32Next(snapshot, &entry); err != nil {
			if err == windows.ERROR_NO_MORE_FILES {
				return fmt.Errorf("找不到进程 %d 的主线程", pid)
			}
			return err
		}
	}
}

func (p *windowsExecProcess) Kill() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.job == 0 {
		return nil
	}
	return windows.TerminateJobObject(p.job, 1)
}

func (p *windowsExecProcess) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.job == 0 {
		return nil
	}
	job := p.job
	p.job = 0
	return windows.CloseHandle(job)
}
