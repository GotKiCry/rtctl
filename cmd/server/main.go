// rtctl-server 控制服务器：设备注册、指令路由、审计。
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"rtctl/internal/server"
)

func main() {
	listen := flag.String("listen", ":8080", "监听地址")
	devicesFile := flag.String("devices", "devices.json", "设备清单文件（JSON）")
	clientKey := flag.String("client-key", "", "客户端连接密钥（可选，设置后 client 必须 -key 认证）")
	tlsCert := flag.String("tls-cert", "", "TLS 证书路径（设置后启用 WSS）")
	tlsKey := flag.String("tls-key", "", "TLS 私钥路径")
	auditFile := flag.String("audit", "audit.log", "审计日志路径")
	allowAnyOrigin := flag.Bool("allow-any-origin", false, "放行任意 Origin（Web 端接入用；默认仅允许无 Origin 或同源）")
	flag.Parse()

	if (*tlsCert == "") != (*tlsKey == "") {
		log.Fatal("-tls-cert 与 -tls-key 必须同时提供")
	}

	data, err := os.ReadFile(*devicesFile)
	if err != nil {
		log.Fatalf("读取设备清单失败: %v", err)
	}
	var cfg server.Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("解析设备清单失败: %v", err)
	}
	if len(cfg.Devices) == 0 {
		log.Fatal("设备清单为空")
	}
	audit, err := server.NewAudit(*auditFile)
	if err != nil {
		log.Fatalf("打开审计日志失败: %v", err)
	}
	defer audit.Close()

	hub, err := server.NewHub(&cfg, *clientKey, audit)
	if err != nil {
		log.Fatalf("设备清单无效: %v", err)
	}
	srv := &server.Server{Hub: hub, AllowAnyOrigin: *allowAnyOrigin}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", srv.HandleWS)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	httpSrv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       0, // WebSocket 长连接不能设置总读超时
		WriteTimeout:      0,
		IdleTimeout:       120 * time.Second,
	}

	log.Printf("rtctl-server 启动，监听 %s，设备 %d 台", *listen, len(cfg.Devices))
	if *tlsCert != "" {
		log.Fatal(httpSrv.ListenAndServeTLS(*tlsCert, *tlsKey))
	} else {
		log.Fatal(httpSrv.ListenAndServe())
	}
}
