//go:build linux

package agent

import "os/exec"

type linuxExecProcess struct {
	cmd  *exec.Cmd
	sudo bool
}

func startExecProcess(cmd *exec.Cmd, sudo bool) (execProcess, error) {
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &linuxExecProcess{cmd: cmd, sudo: sudo}, nil
}

func (p *linuxExecProcess) Kill() error {
	killProcessTree(p.cmd, p.sudo)
	return nil
}

func (p *linuxExecProcess) Close() error { return nil }
