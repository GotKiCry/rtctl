// rtctl-agent 被控端：部署在目标 Linux / Windows 设备上，连接服务器并执行指令。
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
	serverURL := flag.String("server", "ws://127.0.0.1:8080/ws?role=agent", "服务器 WebSocket 地址")
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

	a := agent.New(*serverURL, *id, *token)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("rtctl-agent 启动: id=%s server=%s", *id, *serverURL)
	if err := a.Run(ctx); err != nil {
		log.Fatalf("agent 退出: %v", err)
	}
}
