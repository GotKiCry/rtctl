#!/usr/bin/env bash
# ============================================================
# rtctl 一键部署脚本（唯一入口，Linux，纯直连版）
# ============================================================
# 用法:
#   ① 每台被控机（装 agent，自带监听）:
#       bash deploy.sh agent --listen :8443 --id <设备ID> --token <token>
#   ② 操作机（装 clientd，给 AI Agent 直控）:
#       bash deploy.sh clientd --devices <设备清单（条目带 url）> [--listen 127.0.0.1:18080] [--api-key K]
#   ③ 操作机（拿 client CLI）:
#       bash deploy.sh client
#   ④ 升级到仓库最新二进制:
#       bash deploy.sh update agent|client|clientd
#
# 二进制来源: 本地 ./bin 优先；缺省自动从 GitHub 下载（无需编译）。
#   私有仓库/内网镜像: 设 GH_BASE 与 GH_TOKEN 环境变量。
#
# 免下载直跑（任一台机器，前提是能访问 GitHub）:
#   curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh
#   bash deploy.sh agent --listen :8443 --id jp-tokyo-01 --token <token>
# ============================================================

set -euo pipefail
cd "$(dirname "$0")"

GH_BASE="${GH_BASE:-https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin}"
GH_TOKEN="${GH_TOKEN:-}"

log()  { echo "[rtctl] $*"; }
fail() { echo "[rtctl] 错误: $*" >&2; exit 1; }

# ---------- 工具函数 ----------

get_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    *) fail "不支持的架构 $(uname -m)（支持 x86_64 / aarch64）" ;;
  esac
}

# get_bin <name>：优先本地 bin/，否则从 GH_BASE 下载并做 ELF 魔数校验
get_bin() {
  local name="$1"
  local out="bin/$name"
  if [[ -s "$out" ]]; then
    echo "$out"; return
  fi
  log "下载 $name ..."
  mkdir -p bin
  local auth=()
  [[ -n "$GH_TOKEN" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
  curl -fsSL "${auth[@]}" "$GH_BASE/$name" -o "$out" || fail "下载失败: $GH_BASE/$name（私有仓库请设 GH_TOKEN）"
  local magic
  magic="$(head -c 4 "$out" 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
  [[ "$magic" == "7f454c46" ]] || fail "$name 不是有效的 ELF 二进制（magic=$magic）"
  chmod +x "$out"
  echo "$out"
}

gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24 2>/dev/null && return
  fi
  head -c24 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

ensure_user() { # ensure_user <name>：存在即返回，否则创建 nologin 用户
  local u="$1"
  [[ "$u" == "root" ]] && return
  id "$u" &>/dev/null || useradd -r -s /usr/sbin/nologin "$u" || fail "创建用户 $u 失败"
}

# ---------- ① agent ----------

cmd_agent() {
  local id="" token="" run_user="rtctl-agent" listen="" tls_cert="" tls_key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --listen)     listen="$2"; shift 2 ;;
      --tls-cert)   tls_cert="$2"; shift 2 ;;
      --tls-key)    tls_key="$2"; shift 2 ;;
      --id)         id="$2"; shift 2 ;;
      --token)      token="$2"; shift 2 ;;
      --user)       run_user="$2"; shift 2 ;;
      *) fail "未知参数: $1" ;;
    esac
  done
  [[ -n "$listen" && -n "$id" && -n "$token" ]] || fail "--listen / --id / --token 必填"
  { [[ -n "$tls_cert" && -n "$tls_key" ]] || [[ -z "$tls_cert" && -z "$tls_key" ]]; } \
    || fail "--tls-cert 与 --tls-key 必须同时提供"
  [[ $EUID -eq 0 ]] || fail "agent 安装需要 root（sudo bash deploy.sh agent ...）"

  local bin
  bin="$(get_bin "agent-linux-$(get_arch)")"
  ensure_user "$run_user"
  mkdir -p /etc/rtctl
  # 先停旧服务，避免覆盖运行中的可执行文件报 text file busy
  systemctl stop rtctl-agent 2>/dev/null || true
  install -m 755 "$bin" /usr/local/bin/rtctl-agent
  echo "$token" > /etc/rtctl/agent.token && chmod 600 /etc/rtctl/agent.token

  local exec_args="-listen \"$listen\""
  [[ -n "$tls_cert" ]] && exec_args+=" -tls-cert \"$tls_cert\" -tls-key \"$tls_key\""
  exec_args+=" -id \"$id\""

  cat > /etc/systemd/system/rtctl-agent.service <<EOF
[Unit]
Description=rtctl agent ($id)
After=network-online.target
Wants=network-online.target

[Service]
User=$run_user
Environment=RTCTL_TOKEN=$token
ExecStart=/usr/local/bin/rtctl-agent $exec_args
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rtctl-agent
  sleep 2
  systemctl is-active --quiet rtctl-agent || fail "启动失败，journalctl -u rtctl-agent 查看"

  local port="${listen##*:}"
  log "✔ agent ($id) 已安装并启动：监听 $listen（开机自启，低权限用户 $run_user）"
  log "  验证: client -server ws://<本机IP>:$port/ws exec -token $token 'uptime'"
  log "  clientd 设备清单片段:"
  log "    { \"devices\": [ { \"id\": \"$id\", \"url\": \"ws://<本机IP>:$port/ws\", \"token\": \"$token\" } ] }"
}

# ---------- ② clientd ----------

cmd_clientd() {
  local devices="" listen="127.0.0.1:18080" api_key="" run_user="rtctl"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --devices)    devices="$2"; shift 2 ;;
      --listen)     listen="$2"; shift 2 ;;
      --api-key)    api_key="$2"; shift 2 ;;
      --user)       run_user="$2"; shift 2 ;;
      *) fail "未知参数: $1" ;;
    esac
  done
  [[ -n "$devices" && -f "$devices" ]] || fail "--devices <设备清单文件> 必填（文件需存在；每条设备带 url 直连地址）"
  [[ $EUID -eq 0 ]] || fail "需要 root（sudo bash deploy.sh clientd ...）"

  local bin
  bin="$(get_bin "client-linux-$(get_arch)")"
  ensure_user "$run_user"
  install -m 755 "$bin" /usr/local/bin/rtctl-client
  [[ -z "$api_key" ]] && api_key="$(gen_token)"
  mkdir -p /etc/rtctl
  systemctl stop rtctl-clientd 2>/dev/null || true
  cp "$devices" /etc/rtctl/clientd-devices.json
  chmod 600 /etc/rtctl/clientd-devices.json
  chown "$run_user" /etc/rtctl/clientd-devices.json

  cat > /etc/systemd/system/rtctl-clientd.service <<EOF
[Unit]
Description=rtctl client service (HTTP API for AI agents)
After=network-online.target
Wants=network-online.target

[Service]
User=$run_user
ExecStart=/usr/local/bin/rtctl-client -client-id clientd serve -listen $listen -devices /etc/rtctl/clientd-devices.json -api-key "$api_key"
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rtctl-clientd
  sleep 1
  systemctl is-active --quiet rtctl-clientd || fail "启动失败，journalctl -u rtctl-clientd 查看"

  log "✔ clientd 已启动并开机自启: http://$listen"
  log "  API 密钥: $api_key（Authorization: Bearer $api_key）"
  log "  测试: curl -H 'Authorization: Bearer $api_key' http://$listen/api/v1/devices"
}

# ---------- ③ client ----------

cmd_client() {
  local bin
  bin="$(get_bin "client-linux-$(get_arch)")"
  log "✔ client 就绪: $bin"
  log "  用法: $bin -server ws://<设备IP>:<端口>/ws exec -token <设备token> 'uptime'"
}

# ---------- ④ update ----------

cmd_update() {
  local comp="${1:-}"
  [[ -n "$comp" ]] || fail "用法: bash deploy.sh update agent|client|clientd"
  local name
  case "$comp" in
    agent)   name="agent-linux-$(get_arch)" ;;
    client|clientd) name="client-linux-$(get_arch)" ;;
    *) fail "未知组件 $comp" ;;
  esac
  local bin
  bin="$(get_bin "$name")"
  case "$comp" in
    agent)   [[ $EUID -eq 0 ]] || fail "需要 root"; systemctl stop rtctl-agent 2>/dev/null || true;   install -m 755 "$bin" /usr/local/bin/rtctl-agent;  systemctl restart rtctl-agent;  log "✔ agent 已更新并重启" ;;
    clientd) [[ $EUID -eq 0 ]] || fail "需要 root"; systemctl stop rtctl-clientd 2>/dev/null || true; install -m 755 "$bin" /usr/local/bin/rtctl-client; systemctl restart rtctl-clientd; log "✔ clientd 已更新并重启" ;;
    client)  log "✔ client 已更新: $bin" ;;
  esac
}

# ---------- 入口 ----------

case "${1:-}" in
  agent)   shift; cmd_agent "$@" ;;
  clientd) shift; cmd_clientd "$@" ;;
  client)  cmd_client ;;
  update)  shift; cmd_update "${1:-}" ;;
  -h|--help|"")
    cat <<EOF
rtctl 一键部署脚本（纯直连版）

用法:
  bash deploy.sh agent --listen :8443 --id <设备ID> --token <token> [--tls-cert C --tls-key K]
      在被控机安装 agent（自带 WS 监听，client/clientd 直连）

  bash deploy.sh clientd --devices <设备清单> [--listen 127.0.0.1:18080] [--api-key K]
      在操作机安装常驻 HTTP 服务（AI Agent 直控入口；设备清单每条带 url）

  bash deploy.sh client
      在操作机取 client 二进制

  bash deploy.sh update agent|client|clientd
      拉取仓库最新二进制并重启服务

二进制来源: 本地 ./bin 优先；缺省自动从 GitHub 下载（设 GH_BASE/GH_TOKEN 可指向私有源或镜像）
EOF
    exit 0 ;;
  *) fail "未知命令: $1（agent / clientd / client / update）" ;;
esac
