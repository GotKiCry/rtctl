//go:build !linux && !windows

// firewall_other.go —— 其他平台的防火墙放行：不做（无通用工具）。
package main

// openFirewallPort 在其他平台不做操作。
func openFirewallPort(listen string) (firewallResult, error) {
	return firewallResult{}, nil
}
