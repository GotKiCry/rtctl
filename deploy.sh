#!/usr/bin/env bash
# ============================================================
# rtctl 一键部署脚本（唯一入口，Linux）
# ============================================================
# 用法:
#   ① 中心机（装中继服务器，自动为每台设备生成 token）:
#       bash deploy.sh server [--port 8443] [--client-key K] [--tls-cert C --tls-key K] <设备ID> [设备ID...]
#   ② 每台被控机（装 agent）:
#       bash deploy.sh agent --server-url wss://中继:8443/ws?role=agent --id <设备ID> --token <token>
#   ③ 操作机（拿 client）:
#       bash deploy.sh client
#   ④ 升级到仓库最新二进制:
#       bash deploy.sh update server|agent|client
#
# 二进制来源: 本地 ./bin 优先；缺省自动从 GitHub 下载（无需编译）。
#   私有仓库/内网镜像: 设 GH_BASE 与 GH_TOKEN 环境变量。
#
# 免下载直跑（任一台机器，前提是能访问 GitHub）:
#   curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh
#   bash deploy.sh server <设备ID...>
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

curl_auth=()
[[ -n "$GH_TOKEN" ]] && curl_auth=(-H "Authorization: Bearer $GH_TOKEN")

# ---------- ① server ----------

cmd_server() {
  local port=8443 client_key="" tls_cert="" tls_key="" listen_ip="0.0.0.0" run_user="rtctl" ids=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)      port="$2"; shift 2 ;;
      --client-key) client_key="$2"; shift 2 ;;
      --tls-cert)  tls_cert="$2"; shift 2 ;;
      --tls-key)   tls_key="$2"; shift 2 ;;
      --listen-ip) listen_ip="$2"; shift 2 ;;
      --user)      run_user="$2"; shift 2 ;;
      *)           ids+=("$1"); shift ;;
    esac
  done
  [[ ${#ids[@]} -gt 0 ]] || fail "至少给一个设备 ID，例如: bash deploy.sh server web-01 db-01"
  { [[ -n "$tls_cert" && -n "$tls_key" ]] || [[ -z "$tls_cert" && -z "$tls_key" ]]; } \
    || fail "--tls-cert 与 --tls-key 必须同时提供"
  [[ $EUID -eq 0 ]] || fail "server 安装需要 root（sudo bash deploy.sh server ...）"

  local bin
  bin="$(get_bin "server-linux-$(get_arch)")"
  ensure_user "$run_user"
  mkdir -p /etc/rtctl /var/log/rtctl
  install -m 755 "$bin" /usr/local/bin/rtctl-server
  touch /var/log/rtctl/audit.log && chown "$run_user" /var/log/rtctl/audit.log && chmod 600 /var/log/rtctl/audit.log

  [[ -z "$client_key" ]] && client_key="$(gen_token)"
  log "客户端密钥: $client_key（client 连接用 -key）"

  local devices_json='{ "devices": ['
  : > /etc/rtctl/tokens.txt
  local i
  for i in "${!ids[@]}"; do
    local id="${ids[$i]}" token
    token="$(gen_token)"
    if [[ $i -gt 0 ]]; then devices_json+=','; fi
    devices_json+=" { \"id\": \"$id\", \"token\": \"$token\" }"
    echo "设备 $id 的 token: $token" >> /etc/rtctl/tokens.txt
  done
  devices_json+=' ] }'
  echo "$devices_json" > /etc/rtctl/devices.json
  chmod 600 /etc/rtctl/devices.json /etc/rtctl/tokens.txt
  chown "$run_user" /etc/rtctl/devices.json /etc/rtctl/tokens.txt
  log "已为 ${#ids[@]} 台设备生成 token（/etc/rtctl/tokens.txt）"

  local tls_args=()
  [[ -n "$tls_cert" ]] && tls_args=(-tls-cert "$tls_cert" -tls-key "$tls_key")
  cat > /etc/systemd/system/rtctl-server.service <<EOF
[Unit]
Description=rtctl relay server
After=network-online.target
Wants=network-online.target

[Service]
User=$run_user
ExecStart=/usr/local/bin/rtctl-server -listen $listen_ip:$port -devices /etc/rtctl/devices.json -client-key "$client_key" ${tls_args[@]+"${tls_args[@]}"} -audit /var/log/rtctl/audit.log
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rtctl-server
  sleep 1
  systemctl is-active --quiet rtctl-server || fail "服务启动失败，查看 journalctl -u rtctl-server"

  local scheme="ws"; [[ -n "$tls_cert" ]] && scheme="wss"
  local health="http"; [[ -n "$tls_cert" ]] && health="https"
  curl -sk --max-time 3 "$health://127.0.0.1:$port/healthz" | grep -q ok \
    && log "✔ 服务已启动，healthz ok" || log "✔ 服务已启动（healthz 未探测到，检查端口/证书）"

  log "================ 部署完成 ================"
  log "服务器地址: $scheme://<本机IP>:$port/ws   客户端密钥: $client_key"
  log ""
  log "每台被控机执行（Linux 一条命令，token 见 /etc/rtctl/tokens.txt）:"
  log "  curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh -o deploy.sh"
  log "  bash deploy.sh agent --server-url $scheme://<本机IP>:$port/ws?role=agent --id ${ids[0]} --token <该设备token>"
  log "Windows 被控机（管理员 PowerShell）:"
  log "  irm https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.ps1 -OutFile deploy.ps1"
  log "  .\\deploy.ps1 -Mode Agent -ServerUrl '$scheme://<本机IP>:$port/ws?role=agent' -Id ${ids[0]} -Token '<该设备token>'"
  log "操作机验证:"
  log "  bash deploy.sh client && ./bin/client-linux-$(get_arch) -server $scheme://<本机IP>:$port/ws?role=client -key '$client_key' list"
  log "=========================================="
}

# ---------- ② agent ----------

cmd_agent() {
  local server_url="" id="" token="" run_user="rtctl-agent" listen="" tls_cert="" tls_key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-url) server_url="$2"; shift 2 ;;
      --listen)     listen="$2"; shift 2 ;;
      --tls-cert)   tls_cert="$2"; shift 2 ;;
      --tls-key)    tls_key="$2"; shift 2 ;;
      --id)         id="$2"; shift 2 ;;
      --token)      token="$2"; shift 2 ;;
      --user)       run_user="$2"; shift 2 ;;
      *) fail "未知参数: $1" ;;
    esac
  done
  [[ -n "$id" && -n "$token" ]] || fail "--id 与 --token 必填"
  { [[ -n "$server_url" && -z "$listen" ]] || [[ -z "$server_url" && -n "$listen" ]]; } \
    || fail "中继模式 --server-url 与直连模式 --listen 必须二选一"
  { [[ -n "$tls_cert" && -n "$tls_key" ]] || [[ -z "$tls_cert" && -z "$tls_key" ]]; } \
    || fail "--tls-cert 与 --tls-key 必须同时提供"
  [[ $EUID -eq 0 ]] || fail "agent 安装需要 root（sudo bash deploy.sh agent ...）"

  local bin
  bin="$(get_bin "agent-linux-$(get_arch)")"
  ensure_user "$run_user"
  mkdir -p /etc/rtctl
  install -m 755 "$bin" /usr/local/bin/rtctl-agent
  echo "$token" > /etc/rtctl/agent.token && chmod 600 /etc/rtctl/agent.token

  local exec_args
  if [[ -n "$listen" ]]; then
    exec_args="-listen \"$listen\""
    [[ -n "$tls_cert" ]] && exec_args+=" -tls-cert \"$tls_cert\" -tls-key \"$tls_key\""
    exec_args+=" -id \"$id\""
  else
    exec_args="-server \"$server_url\" -id \"$id\""
  fi

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
  systemctl is-active --quiet rtctl-agent || fail "启动失败（token/id 不匹配会立即退出），journalctl -u rtctl-agent 查看"

  if [[ -n "$listen" ]]; then
    local port="${listen##*:}"
    log "✔ agent ($id) 直连模式已启动并自启：监听 $listen（无需中继；client/clientd 直连，需持设备 token）"
    log "  验证: client -server ws://<本机IP>:$port/ws exec -token $token 'uptime'"
    log "  clientd 直连: 设备清单里加 \"url\": \"ws://<本机IP>:$port/ws\" 即可"
  else
    log "✔ agent ($id) 已安装并启动（低权限用户 $run_user；需系统管理权限请重装时加 --user root）"
    log "  日志: journalctl -u rtctl-agent -f"
    log "  验证: 操作机 client list 应看到 $id 在线"
  fi
}

# ---------- ③ client ----------

cmd_client() {
  local bin
  bin="$(get_bin "client-linux-$(get_arch)")"
  log "✔ client 就绪: $bin"
  log "  用法: $bin -server wss://中继:8443/ws?role=client -key <客户端密钥> list"
}

# ---------- ④ clientd：常驻 HTTP 服务（给 AI Agent 调用的入口） ----------

cmd_clientd() {
  local server_url="" client_key_val="" devices="" listen="127.0.0.1:18080" api_key="" run_user="rtctl"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-url) server_url="$2"; shift 2 ;;
      --client-key) client_key_val="$2"; shift 2 ;;
      --devices)    devices="$2"; shift 2 ;;
      --listen)     listen="$2"; shift 2 ;;
      --api-key)    api_key="$2"; shift 2 ;;
      --user)       run_user="$2"; shift 2 ;;
      *) fail "未知参数: $1" ;;
    esac
  done
  [[ -n "$devices" && -f "$devices" ]] \
    || fail "--devices <设备清单文件> 必填（文件需存在；条目可带 url 直连、不带 url 经中继）"
  [[ $EUID -eq 0 ]] || fail "需要 root（sudo bash deploy.sh clientd ...）"

  local bin
  bin="$(get_bin "client-linux-$(get_arch)")"
  ensure_user "$run_user"
  install -m 755 "$bin" /usr/local/bin/rtctl-client
  [[ -z "$api_key" ]] && api_key="$(gen_token)"
  mkdir -p /etc/rtctl
  cp "$devices" /etc/rtctl/clientd-devices.json
  chmod 600 /etc/rtctl/clientd-devices.json
  chown "$run_user" /etc/rtctl/clientd-devices.json

  local relay_args=""
  [[ -n "$server_url" ]] && relay_args="-server \"$server_url\" -key \"$client_key_val\""
  cat > /etc/systemd/system/rtctl-clientd.service <<EOF
[Unit]
Description=rtctl client service (HTTP API for AI agents)
After=network-online.target
Wants=network-online.target

[Service]
User=$run_user
ExecStart=/usr/local/bin/rtctl-client $relay_args -client-id clientd serve -listen $listen -devices /etc/rtctl/clientd-devices.json -api-key "$api_key"
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
  log "  exec: curl -H 'Authorization: Bearer $api_key' -d '{\"device_id\":\"web-01\",\"cmd\":\"uptime\"}' http://$listen/api/v1/exec"
}

# ---------- ⑤ update ----------

cmd_update() {
  local comp="${1:-}"
  [[ -n "$comp" ]] || fail "用法: bash deploy.sh update server|agent|client"
  local name
  case "$comp" in
    server)  name="server-linux-$(get_arch)" ;;
    agent)   name="agent-linux-$(get_arch)" ;;
    client|clientd) name="client-linux-$(get_arch)" ;;
    *) fail "未知组件 $comp" ;;
  esac
  local bin
  bin="$(get_bin "$name")"
  case "$comp" in
    server) [[ $EUID -eq 0 ]] || fail "需要 root"; install -m 755 "$bin" /usr/local/bin/rtctl-server; systemctl restart rtctl-server; log "✔ server 已更新并重启" ;;
    agent)  [[ $EUID -eq 0 ]] || fail "需要 root"; install -m 755 "$bin" /usr/local/bin/rtctl-agent;  systemctl restart rtctl-agent;  log "✔ agent 已更新并重启" ;;
    clientd) [[ $EUID -eq 0 ]] || fail "需要 root"; install -m 755 "$bin" /usr/local/bin/rtctl-client; systemctl restart rtctl-clientd; log "✔ clientd 已更新并重启" ;;
    client) log "✔ client 已更新: $bin" ;;
  esac
}

# ---------- 入口 ----------

case "${1:-}" in
  server)  shift; cmd_server "$@" ;;
  agent)   shift; cmd_agent "$@" ;;
  client)  cmd_client ;;
  clientd) shift; cmd_clientd "$@" ;;
  update)  shift; cmd_update "${1:-}" ;;
  -h|--help|"")
    cat <<EOF
rtctl 一键部署脚本

用法:
  bash deploy.sh server [--port 8443] [--client-key K] [--tls-cert C --tls-key K] <设备ID...>
      在中心机安装中继服务器，自动为每台设备生成高熵 token（保存在 /etc/rtctl/tokens.txt）

  bash deploy.sh agent --server-url <wss://中继:端口/ws?role=agent> --id <设备ID> --token <token> [--user root]
      在被控机安装 agent（中继模式：主动拨出，可穿透 NAT）

  bash deploy.sh agent --listen :8443 --id <设备ID> --token <token> [--tls-cert C --tls-key K]
      在被控机安装 agent（直连模式：agent 自带监听，无需中继；目标机需可被访问）

  bash deploy.sh client
      在操作机取 client 二进制

  bash deploy.sh clientd [--server-url <wss://中继:端口/ws?role=client> --client-key K] --devices <设备清单> [--listen 127.0.0.1:18080] [--api-key K]
      在操作机安装常驻 HTTP 服务（AI Agent 调用入口，免手动复制指令/传输文件）
      设备清单条目带 url 直连 agent（无需中继）；不带 url 经中继（--server-url 必填）

  bash deploy.sh update server|agent|client|clientd
      拉取仓库最新二进制并重启服务

二进制来源: 本地 ./bin 优先；缺省自动从 GitHub 下载（设 GH_BASE/GH_TOKEN 可指向私有源或镜像）
EOF
    exit 0 ;;
  *) fail "未知命令: $1（server / agent / client / clientd / update）" ;;
esac
