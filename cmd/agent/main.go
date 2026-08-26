// rtctl-agent 被控端：部署在目标 Linux / Windows 设备上。
// 直连模式：agent 自带 WS 服务端，本机 client 直接连接。
//
// 启动方式（二选一）：
//
//	./rtctl-agent            # 读同目录 agent.conf（或用 -config 指定路径）
//	./rtctl-agent -init      # 生成 agent.conf（含随机 token）并打印连接信息
//	./rtctl-agent -listen :8443 -id node-01 -token <token>   # 纯命令行
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"rtctl/internal/agent"
)

const configName = "agent.conf"

// cfg agent 配置。字段对应 agent.conf 的 key。
type cfg struct {
	listen    string
	id        string
	token     string
	tlsCert   string
	tlsKey    string
	allowSudo bool
}

// loadConfig 解析 agent.conf（key = value，# 或 ; 注释，空行忽略）。
func loadConfig(path string) (cfg, error) {
	var c cfg
	f, err := os.Open(path)
	if err != nil {
		return c, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "listen":
			c.listen = strings.TrimSpace(v)
		case "id":
			c.id = strings.TrimSpace(v)
		case "token":
			c.token = strings.TrimSpace(v)
		case "tls_cert":
			c.tlsCert = strings.TrimSpace(v)
		case "tls_key":
			c.tlsKey = strings.TrimSpace(v)
		case "allow_sudo":
			c.allowSudo, _ = strconv.ParseBool(strings.TrimSpace(v))
		}
	}
	return c, sc.Err()
}

// writeConfig 写配置（0600：token 属凭据）。
func writeConfig(path string, c cfg) error {
	content := fmt.Sprintf("# rtctl-agent 配置（token 即设备钥匙，请勿外泄）\n"+
		"listen = %s\n"+
		"id = %s\n"+
		"token = %s\n"+
		"tls_cert = %s\n"+
		"tls_key = %s\n"+
		"allow_sudo = %v\n", c.listen, c.id, c.token, c.tlsCert, c.tlsKey, c.allowSudo)
	return os.WriteFile(path, []byte(content), 0o600)
}

// defaultConfigPath 返回默认配置路径：先 exe 同目录，回退当前工作目录。
func defaultConfigPath() string {
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), configName)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return filepath.Join(".", configName)
}

// genToken 生成高熵 token（32 字节 = 64 hex 字符）。
func genToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// hostnameOrDefault 取主机名（供默认设备 ID）。
func hostnameOrDefault() string {
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return "node"
}

func main() {
	configPath := flag.String("config", "", "配置文件路径（默认 exe 同目录或当前目录的 agent.conf）")
	initMode := flag.Bool("init", false, "生成 agent.conf（含随机 token）并打印连接信息后退出")
	listen := flag.String("listen", "", "监听地址（如 :8443；缺省取配置/默认 :8443）")
	id := flag.String("id", "", "设备 ID（或环境变量 RTCTL_ID）")
	token := flag.String("token", "", "设备 token（或环境变量 RTCTL_TOKEN）")
	tlsCert := flag.String("tls-cert", "", "TLS 证书路径（与 -tls-key 同时提供则启用 WSS）")
	tlsKey := flag.String("tls-key", "", "TLS 私钥路径")
	allowSudo := flag.Bool("allow-sudo", false, "允许特权命令（sudo:true 经 sudo 提权；需 sudoers 放行，默认关闭）")
	flag.Parse()

	if *configPath == "" {
		*configPath = defaultConfigPath()
	}

	// ---- -init：生成配置并打印连接信息 ----
	if *initMode {
		if _, err := os.Stat(*configPath); err == nil {
			log.Fatalf("配置文件已存在: %s（如需重新生成请先删除或手动编辑）", *configPath)
		}
		c := cfg{listen: ":8443", id: hostnameOrDefault()}
		if *listen != "" {
			c.listen = *listen
		}
		if *id != "" {
			c.id = *id
		} else if e := os.Getenv("RTCTL_ID"); e != "" {
			c.id = e
		}
		if *token != "" {
			c.token = *token
		} else if e := os.Getenv("RTCTL_TOKEN"); e != "" {
			c.token = e
		} else {
			t, err := genToken()
			if err != nil {
				log.Fatalf("生成 token 失败: %v", err)
			}
			c.token = t
		}
		c.tlsCert, c.tlsKey, c.allowSudo = *tlsCert, *tlsKey, *allowSudo
		if err := writeConfig(*configPath, c); err != nil {
			log.Fatalf("写入配置失败: %v", err)
		}
		fmt.Printf("✔ 配置已生成: %s\n", *configPath)
		fmt.Printf("  设备 ID      : %s\n", c.id)
		fmt.Printf("  监听地址    : %s%s\n", c.listen, tlsNote(c.tlsCert))
		fmt.Printf("  设备 token  : %s\n", c.token)
		fmt.Printf("\n本机连接示例（把 <IP> 换成目标机地址）:\n  rtctl <IP>%s <token> 'uptime'\n", c.listen)
		fmt.Printf("\n⚠️  安全警告: token 即设备全部权限，请仅通过安全渠道保存/分享；\n   公网服务器建议配置 tls_cert / tls_key 启用加密传输。\n")
		return
	}

	// ---- 启动：flag > 配置文件 > 环境变量 > 默认 ----
	c := cfg{listen: ":8443"}
	if loaded, err := loadConfig(*configPath); err == nil {
		c = loaded
		if c.listen == "" {
			c.listen = ":8443"
		}
	} else if !os.IsNotExist(err) {
		log.Fatalf("读取配置失败 %s: %v", *configPath, err)
	}

	if *listen != "" {
		c.listen = *listen
	}
	if *id != "" {
		c.id = *id
	} else if c.id == "" {
		c.id = os.Getenv("RTCTL_ID")
	}
	if *token != "" {
		c.token = *token
	} else if c.token == "" {
		c.token = os.Getenv("RTCTL_TOKEN")
	}
	if *tlsCert != "" {
		c.tlsCert = *tlsCert
	}
	if *tlsKey != "" {
		c.tlsKey = *tlsKey
	}
	if *allowSudo {
		c.allowSudo = true
	}

	if c.id == "" || c.token == "" {
		log.Fatalf("缺少设备 ID/token：编辑 %s 或运行 %s -init 自动生成（也可 -id/-token 或环境变量 RTCTL_ID/RTCTL_TOKEN）", *configPath, os.Args[0])
	}
	if (c.tlsCert == "") != (c.tlsKey == "") {
		log.Fatal("-tls-cert 与 -tls-key 必须同时提供（或同时留空）")
	}

	a := agent.New(c.id, c.token)
	a.AllowSudo = c.allowSudo
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	log.Printf("rtctl-agent 启动: id=%s listen=%s tls=%v allow-sudo=%v token=%s（配置: %s）",
		c.id, c.listen, c.tlsCert != "", c.allowSudo, c.token, *configPath)
	log.Printf("⚠️  安全警告: token 即设备全部权限，日志已打印 token，请勿外泄；公网服务器请配置 tls_cert / tls_key 启用加密传输")
	if err := a.ServeStandalone(ctx, c.listen, c.tlsCert, c.tlsKey); err != nil {
		log.Fatalf("agent 退出: %v", err)
	}
}

func tlsNote(cert string) string {
	if cert != "" {
		return "（WSS）"
	}
	return ""
}
