// rtctl-agent 被控端：部署在目标 Linux / Windows 设备上。
// 直连模式：agent 自带 WS 服务端，client / clientd 直接连接。
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
	listen := flag.String("listen", ":8443", "监听地址（如 :8443 或 1.2.3.4:8443）")
	tlsCert := flag.String("tls-cert", "", "TLS 证书路径")
	tlsKey := flag.String("tls-key", "", "TLS 私钥路径")
	allowAnyOrigin := flag.Bool("allow-any-origin", false, "放行任意 Origin（Web 接入用）")
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

	a := agent.New(*id, *token)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("rtctl-agent 启动: id=%s listen=%s（直连模式，无需中继）", *id, *listen)
	if err := a.ServeStandalone(ctx, *listen, *tlsCert, *tlsKey, *allowAnyOrigin); err != nil {
		log.Fatalf("agent 退出: %v", err)
	}
}
