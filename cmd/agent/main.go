// rtctl-agent 被控端：部署在目标 Linux / Windows 设备上。
//
// 两种模式：
//  1. 中继模式（默认）：连接服务器并执行指令（可穿透 NAT，无需公网 IP）
//  2. 直连模式（-listen）：agent 自带 WS 服务端，client/clientd 直接连接，
//     无需中继 server（适合目标机可被直接访问的场景）
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"rtctl/internal/agent"
)

func main() {
	serverURL := flag.String("server", "ws://127.0.0.1:8080/ws?role=agent", "服务器 WebSocket 地址（中继模式）")
	listen := flag.String("listen", "", "直连模式监听地址（如 :8443 或 1.2.3.4:8443；设置后无需中继）")
	tlsCert := flag.String("tls-cert", "", "直连模式 TLS 证书路径")
	tlsKey := flag.String("tls-key", "", "直连模式 TLS 私钥路径")
	allowAnyOrigin := flag.Bool("allow-any-origin", false, "直连模式放行任意 Origin（Web 接入用）")
	id := flag.String("id", "", "设备 ID（或环境变量 RTCTL_ID）")
	token := flag.String("token", "", "设备 token（或环境变量 RTCTL_TOKEN）")
	flag.Parse()

	if *id == "" {
		*id = os.Getenv("RTCTL_ID")
	}
	if *token == "" {
		*token = os.Getenv("RTCTL_TOKEN")
	}
	if *id == "" || *token == "" {
		log.Fatal("必须提供 -id 和 -token（或用环境变量 RTCTL_ID / RTCTL_TOKEN）")
	}
	if (*tlsCert == "") != (*tlsKey == "") {
		log.Fatal("-tls-cert 与 -tls-key 必须同时提供")
	}

	a := agent.New(*serverURL, *id, *token)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if *listen != "" {
		// 直连模式：无需中继
		log.Printf("rtctl-agent 直连模式启动: id=%s listen=%s", *id, *listen)
		if err := a.ServeStandalone(ctx, *listen, *tlsCert, *tlsKey, *allowAnyOrigin); err != nil {
			log.Fatalf("agent 退出: %v", err)
		}
		return
	}

	log.Printf("rtctl-agent 启动: id=%s server=%s", *id, *serverURL)
	if err := a.Run(ctx); err != nil {
		log.Fatalf("agent 退出: %v", err)
	}
}
