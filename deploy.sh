#!/usr/bin/env bash
# ============================================================
# rtctl 一键部署脚本（纯直连版，v2ray-agent 风格交互菜单）
# ============================================================
# 一条指令直达菜单（root 执行，非 root 自动提权）:
#   wget -P /root -N --no-check-certificate \
#     "https://raw.githubusercontent.com/GotKiCry/rtctl/main/deploy.sh" \
#     && chmod 700 /root/deploy.sh && /root/deploy.sh
#
# 无参数运行进入交互菜单（安装 / 状态 / 信息 / 升级 / 卸载 / 退出）；
# 也支持非交互子命令（脚本化）:
#   bash deploy.sh agent   --listen :8443 --id <设备ID> --token <token>
#   bash deploy.sh clientd --devices <设备清单>
#   bash deploy.sh status        查看状态（无需 root）
#   bash deploy.sh info          查看连接信息（无需 root）
#   bash deploy.sh update  agent|clientd
#   bash deploy.sh uninstall agent|clientd
#
# 二进制来源: 本地 ./bin 优先；缺省自动从 GitHub 下载（无需编译）。
#   私有仓库/内网镜像: 设 GH_BASE 与 GH_TOKEN 环境变量。
# ============================================================

set -euo pipefail

# ---------- 自动提权（非 root 时 sudo 重执行；status/info 只读，无需提权） ----------
is_readonly_cmd() {
  case "${1:-}" in
    status|info|-h|--help) return 0 ;;
    *) return 1 ;;
  esac
}
if [[ $EUID -ne 0 ]] && ! is_readonly_cmd "${1:-}"; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$(readlink -f "$0")" "$@"
  fi
  echo "[rtctl] 需要 root 权限，且未找到 sudo" >&2
  exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"

GH_BASE="${GH_BASE:-https://raw.githubusercontent.com/GotKiCry/rtctl/main/bin}"
GH_TOKEN="${GH_TOKEN:-}"

# ---------- 颜色 ----------
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_NC='\033[0m'
# 注意: log/warn 输出到 stderr，避免污染命令替换（如 bin="$(get_bin ...)"）
log()  { echo -e "${C_GREEN}[rtctl]${C_NC} $*" >&2; }
warn() { echo -e "${C_YELLOW}[提示]${C_NC} $*" >&2; }
fail() { echo -e "${C_RED}[错误]${C_NC} $*" >&2; exit 1; }

# ---------- 工具函数 ----------

get_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64 ;;
    aarch64|arm64)  echo arm64 ;;
    *) fail "不支持的架构 $(uname -m)（支持 x86_64 / aarch64）" ;;
  esac
}

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

ensure_user() {
  local u="$1"
  [[ "$u" == "root" ]] && return
  id "$u" &>/dev/null || useradd -r -s /usr/sbin/nologin "$u" || fail "创建用户 $u 失败"
}

ask_token() { # 交互式 token 引导：自动生成或手动输入（提示走 stderr，避免污染命令替换）
  echo -e "  ${C_CYAN}设备 token:${C_NC}" >&2
  echo "    [1] 自动生成高熵 token（推荐）" >&2
  echo "    [2] 手动输入" >&2
  read -rp "  请选择 [1]: " c
  if [[ "${c:-1}" == "2" ]]; then
    read -rp "  请输入 token: " t
    [[ -n "$t" ]] || fail "token 不能为空"
    echo "$t"
  else
    gen_token
  fi
}

# ---------- 安装: agent ----------

cmd_agent() {
  local id="" token="" run_user="rtctl-agent" listen="" tls_cert="" tls_key="" allow_sudo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --listen)      listen="$2"; shift 2 ;;
      --tls-cert)    tls_cert="$2"; shift 2 ;;
      --tls-key)     tls_key="$2"; shift 2 ;;
      --id)          id="$2"; shift 2 ;;
      --token)       token="$2"; shift 2 ;;
      --user)        run_user="$2"; shift 2 ;;
      --allow-sudo)  allow_sudo="1"; shift ;;
      *) fail "未知参数: $1" ;;
    esac
  done
  [[ -n "$listen" && -n "$id" && -n "$token" ]] || fail "--listen / --id / --token 必填"
  # token 将写入 EnvironmentFile（每行 KEY=value），换行会造成注入
  [[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] || fail "token 不能包含换行符"
  { [[ -n "$tls_cert" && -n "$tls_key" ]] || [[ -z "$tls_cert" && -z "$tls_key" ]]; } \
    || fail "--tls-cert 与 --tls-key 必须同时提供"

  local bin
  bin="$(get_bin "agent-linux-$(get_arch)")"
  ensure_user "$run_user"
  mkdir -p /etc/rtctl
  systemctl stop rtctl-agent 2>/dev/null || true
  install -m 755 "$bin" /usr/local/bin/rtctl-agent
  # token 落 EnvironmentFile（0600 + 属服务账户），不写进 unit（unit 文件 0644 全局可读）
  printf 'RTCTL_TOKEN=%s\n' "$token" > /etc/rtctl/agent.env
  chmod 600 /etc/rtctl/agent.env && chown "$run_user" /etc/rtctl/agent.env
  rm -f /etc/rtctl/agent.token  # 旧版残留清理

  # systemd ExecStart 不做 shell 解析，参数按空格分隔直写即可
  local exec_args="-listen $listen"
  [[ -n "$tls_cert" ]] && exec_args+=" -tls-cert $tls_cert -tls-key $tls_key"
  exec_args+=" -id $id"
  # 特权命令审批：sudo 是 setuid 程序，NoNewPrivileges=true 会阻止提权，
  # 因此仅当用户批准 --allow-sudo 时才放开并写 sudoers（按命令路径最小放行）。
  local nnp="true"
  if [[ -n "$allow_sudo" ]]; then
    exec_args+=" -allow-sudo"
    nnp="false"
    cat > /etc/sudoers.d/rtctl-agent <<EOF
# rtctl agent 提权通道（由 deploy.sh 生成；卸载或重装为不授权时自动删除）
$run_user ALL=(ALL) NOPASSWD: /bin/sh, /usr/bin/sh, /usr/bin/kill, /bin/kill
EOF
    chmod 440 /etc/sudoers.d/rtctl-agent
    visudo -c -f /etc/sudoers.d/rtctl-agent >/dev/null 2>&1 || { rm -f /etc/sudoers.d/rtctl-agent; fail "sudoers 校验失败"; }
  else
    rm -f /etc/sudoers.d/rtctl-agent
  fi

  cat > /etc/systemd/system/rtctl-agent.service <<EOF
[Unit]
Description=rtctl agent ($id)
After=network-online.target
Wants=network-online.target

[Service]
User=$run_user
EnvironmentFile=/etc/rtctl/agent.env
ExecStart=/usr/local/bin/rtctl-agent $exec_args
Restart=always
RestartSec=3
NoNewPrivileges=$nnp

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rtctl-agent
  sleep 2
  systemctl is-active --quiet rtctl-agent || fail "启动失败，journalctl -u rtctl-agent 查看"

  local port="${listen##*:}" ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="<本机IP>"
  log "✔ agent ($id) 已安装并启动：监听 $listen（后台运行 + 开机自启，低权限用户 $run_user）"
  if [[ -n "$allow_sudo" ]]; then
    log "  特权命令: 已授权（sudoers 放行；控制端 exec -sudo 仍需用户确认/批准闸）"
  else
    log "  特权命令: 未授权（sudo:true 将被拒；需要 root 命令就重装并选允许提权）"
  fi
  log "  验证: client -server ws://$ip:$port/ws exec -token $token 'uptime'"
  log "  clientd 设备清单片段:"
  log "    { \"devices\": [ { \"id\": \"$id\", \"url\": \"ws://$ip:$port/ws\", \"token\": \"$token\" } ] }"
  log "  以后随时查看以上信息: bash deploy.sh info（菜单选 4）"
}

# ---------- 安装: clientd ----------

cmd_clientd() {
  local devices="" listen="127.0.0.1:18080" api_key="" run_user="rtctl" allow_sudo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --devices)     devices="$2"; shift 2 ;;
      --listen)      listen="$2"; shift 2 ;;
      --api-key)     api_key="$2"; shift 2 ;;
      --user)        run_user="$2"; shift 2 ;;
      --allow-sudo)  allow_sudo="1"; shift ;;
      *) fail "未知参数: $1" ;;
    esac
  done
  [[ -n "$devices" && -f "$devices" ]] || fail "--devices <设备清单文件> 必填（文件需存在；每条设备带 url 直连地址）"
  [[ "$api_key" != *$'\n'* && "$api_key" != *$'\r'* ]] || fail "api-key 不能包含换行符"

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
  # api-key 走 EnvironmentFile，不进命令行（ps 可见）也不进 unit（0644 全局可读）
  printf 'RTCTL_API_KEY=%s\n' "$api_key" > /etc/rtctl/clientd.env
  chmod 600 /etc/rtctl/clientd.env && chown "$run_user" /etc/rtctl/clientd.env

  local exec_line="/usr/local/bin/rtctl-client -client-id clientd serve -listen $listen -devices /etc/rtctl/clientd-devices.json"
  # 特权命令转发闸：仅用户批准后开启（未开启时 AI Agent 的特权请求一律 403）
  [[ -n "$allow_sudo" ]] && exec_line+=" -allow-sudo"

  cat > /etc/systemd/system/rtctl-clientd.service <<EOF
[Unit]
Description=rtctl client service (HTTP API for AI agents)
After=network-online.target
Wants=network-online.target

[Service]
User=$run_user
EnvironmentFile=/etc/rtctl/clientd.env
ExecStart=$exec_line
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

  log "✔ clientd 已安装并启动：http://$listen（后台运行 + 开机自启）"
  log "  API 密钥: $api_key（Authorization: Bearer $api_key）"
  if [[ -n "$allow_sudo" ]]; then
    log "  特权命令转发: 已开启（sudo:true 请求会被转发）"
  else
    log "  特权命令转发: 关闭（sudo:true 请求一律 403，需用户批准后重装开启）"
  fi
  log "  测试: curl -H 'Authorization: Bearer $api_key' http://$listen/api/v1/devices"
  log "  以后随时查看以上信息: bash deploy.sh info（菜单选 4）"
}

# ---------- 状态 ----------

cmd_status() {
  echo -e "${C_CYAN}rtctl 组件状态:${C_NC}"
  printf "  %-12s %-18s %s\n" "组件" "运行状态" "开机自启"
  echo "  --------------------------------------------"
  for u in rtctl-agent rtctl-clientd; do
    local a e
    if systemctl cat "$u" >/dev/null 2>&1; then
      a="$(systemctl is-active "$u" 2>/dev/null || echo 已安装未运行)"
      e="$(systemctl is-enabled "$u" 2>/dev/null || echo 未启用)"
    else
      a="未安装"
      e="未安装"
    fi
    printf "  %-12s %-18s %s\n" "${u#rtctl-}" "$a" "$e"
  done
  echo
}

# ---------- 连接信息（复制用） ----------

cmd_info() {
  echo -e "${C_CYAN}================ 连接信息（直接复制） ================${C_NC}"
  if systemctl cat rtctl-agent >/dev/null 2>&1; then
    local unit_text exec_line token listen id port ip
    unit_text="$(systemctl cat rtctl-agent 2>/dev/null)"
    exec_line="$(echo "$unit_text" | grep '^ExecStart=' | head -1)"
    listen="$(echo "$exec_line" | grep -o '\-listen [^ ]*' | awk '{print $2}' | tr -d '"')"
    id="$(echo "$exec_line" | grep -o '\-id [^ ]*' | awk '{print $2}' | tr -d '"')"
    # 新版：0600 的 EnvironmentFile（非 root 读不到）；旧版兼容：unit 内联 Environment=
    if [[ -r /etc/rtctl/agent.env ]]; then
      token="$(grep '^RTCTL_TOKEN=' /etc/rtctl/agent.env | head -1 | cut -d= -f2-)"
    else
      token="$(echo "$unit_text" | grep '^Environment=RTCTL_TOKEN=' | head -1 | sed 's/^Environment=RTCTL_TOKEN=//' | tr -d '"')"
    fi
    [[ -n "$token" ]] || token='(token 存于 /etc/rtctl/agent.env，0600 需 root 查看)'
    port="${listen##*:}"
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] || ip="<本机IP>"

    echo -e "  ${C_GREEN}设备 ID:${C_NC}   $id"
    echo -e "  ${C_GREEN}监听地址:${C_NC} $listen"
    echo -e "  ${C_GREEN}token:${C_NC}     $token"
    if echo "$exec_line" | grep -q -- '-allow-sudo'; then
      echo -e "  ${C_GREEN}特权命令:${C_NC} 已授权（控制端 exec -sudo 可提权执行）"
    else
      echo -e "  ${C_GREEN}特权命令:${C_NC} 未授权（sudo:true 将被拒；需 root 命令请重装并选允许提权）"
    fi
    echo
    echo -e "  ${C_YELLOW}── clientd 设备清单片段（复制到控制机 devices.json 即可直连）──${C_NC}"
    echo "  { \"devices\": [ { \"id\": \"$id\", \"url\": \"ws://$ip:$port/ws\", \"token\": \"$token\" } ] }"
    echo
    echo -e "  ${C_YELLOW}── 验证命令（任意有 client 的机器）──${C_NC}"
    echo "  client -server ws://$ip:$port/ws exec -token $token 'uptime'"
  else
    warn "agent 未安装（菜单选 1 先安装）"
  fi

  if systemctl cat rtctl-clientd >/dev/null 2>&1; then
    local hl api_key cd_exec
    cd_exec="$(systemctl cat rtctl-clientd 2>/dev/null | grep '^ExecStart=' | head -1)"
    hl="$(echo "$cd_exec" | grep -o '\-listen [^ ]*' | awk '{print $2}' | tr -d '"')"
    if [[ -r /etc/rtctl/clientd.env ]]; then
      api_key="$(grep '^RTCTL_API_KEY=' /etc/rtctl/clientd.env | head -1 | cut -d= -f2-)"
    else
      api_key="$(echo "$cd_exec" | grep -o '\-api-key [^ ]*' | awk '{print $2}' | tr -d '"')"
    fi
    [[ -n "$api_key" ]] || api_key='(存于 /etc/rtctl/clientd.env，0600 需 root 查看)'
    echo
    echo -e "  ${C_GREEN}── clientd（AI Agent 直控入口）──${C_NC}"
    echo -e "  ${C_GREEN}HTTP 地址:${C_NC} http://$hl"
    echo -e "  ${C_GREEN}API 密钥:${C_NC}  $api_key"
    if echo "$cd_exec" | grep -q -- '-allow-sudo'; then
      echo -e "  ${C_GREEN}特权转发:${C_NC} 已开启（sudo:true 请求会被转发）"
    else
      echo -e "  ${C_GREEN}特权转发:${C_NC} 关闭（sudo:true 请求一律 403 approval_required）"
    fi
    echo "  调用示例: curl -H 'Authorization: Bearer $api_key' -d '{\"device_id\":\"<设备ID>\",\"cmd\":\"uptime\"}' http://$hl/api/v1/exec"
  fi
  echo -e "${C_CYAN}====================================================${C_NC}"
}

# ---------- 卸载 ----------

cmd_uninstall() {
  local comp="${1:-}"
  if [[ -z "$comp" ]]; then
    echo "  要卸载的组件: [1] agent  [2] clientd  [3] 全部"
    read -rp "  请选择 [3]: " c
    case "${c:-3}" in
      1) comp=agent ;;
      2) comp=clientd ;;
      *) comp=all ;;
    esac
  fi
  for c in agent clientd; do
    [[ "$comp" == "all" || "$comp" == "$c" ]] || continue
    local unit="rtctl-$c"
    systemctl disable --now "$unit" 2>/dev/null || true
    rm -f "/etc/systemd/system/$unit.service"
    case "$c" in
      agent)   rm -f /usr/local/bin/rtctl-agent /etc/rtctl/agent.env /etc/rtctl/agent.token /etc/sudoers.d/rtctl-agent ;;
      clientd) rm -f /usr/local/bin/rtctl-client /etc/rtctl/clientd.env /etc/rtctl/clientd-devices.json ;;
    esac
    log "✔ $c 已卸载"
  done
  systemctl daemon-reload
}

# ---------- 升级 ----------

cmd_update() {
  local comp="${1:-}"
  [[ -n "$comp" ]] || fail "用法: bash deploy.sh update agent|clientd"
  local name
  case "$comp" in
    agent)   name="agent-linux-$(get_arch)" ;;
    clientd) name="client-linux-$(get_arch)" ;;
    *) fail "未知组件 $comp" ;;
  esac
  local bin
  bin="$(get_bin "$name")"
  case "$comp" in
    agent)   systemctl stop rtctl-agent 2>/dev/null || true;   install -m 755 "$bin" /usr/local/bin/rtctl-agent;  systemctl restart rtctl-agent;  log "✔ agent 已更新并重启" ;;
    clientd) systemctl stop rtctl-clientd 2>/dev/null || true; install -m 755 "$bin" /usr/local/bin/rtctl-client; systemctl restart rtctl-clientd; log "✔ clientd 已更新并重启" ;;
  esac
}

# ---------- 交互菜单 ----------

menu_agent() {
  echo -e "${C_CYAN}== 安装 agent（被控端：装在目标服务器上，被控制）==${C_NC}"
  local id listen token tls_yn tls_cert tls_key sudo_yn sudo_args
  read -rp "设备 ID（唯一名称，如 jp-tokyo-01）: " id
  [[ -n "$id" ]] || { warn "设备 ID 不能为空"; return; }
  read -rp "监听端口 [8443]: " p
  listen=":${p:-8443}"
  token="$(ask_token)"
  read -rp "启用 WSS（需要证书路径）? [y/N]: " tls_yn
  if [[ "${tls_yn,,}" == "y" ]]; then
    read -rp "证书路径: " tls_cert
    read -rp "私钥路径: " tls_key
  fi
  read -rp "允许 root 提权（特权命令须用户批准后经 sudo 执行）? [y/N]: " sudo_yn
  [[ "${sudo_yn,,}" == "y" ]] && sudo_args="--allow-sudo"
  cmd_agent --listen "$listen" --id "$id" --token "$token" \
    ${tls_cert:+--tls-cert "$tls_cert" --tls-key "$tls_key"} $sudo_args
}

menu_clientd() {
  echo -e "${C_CYAN}== 安装 clientd（AI Agent 直控服务：装在操作机上）==${C_NC}"
  local devices listen api_choice api_key sudo_yn sudo_args
  read -rp "设备清单文件路径（每条设备带 url 直连地址）: " devices
  [[ -f "$devices" ]] || { warn "文件不存在: $devices"; return; }
  read -rp "HTTP 监听地址 [127.0.0.1:18080]: " l
  listen="${l:-127.0.0.1:18080}"
  echo -e "  ${C_CYAN}API 密钥:${C_NC} [1] 自动生成（推荐） [2] 手动输入"
  read -rp "  请选择 [1]: " api_choice
  if [[ "${api_choice:-1}" == "2" ]]; then read -rp "  请输入 API 密钥: " api_key; fi
  read -rp "允许转发特权命令（sudo:true；未开启时 AI Agent 的特权请求一律被拒）? [y/N]: " sudo_yn
  [[ "${sudo_yn,,}" == "y" ]] && sudo_args="--allow-sudo"
  cmd_clientd --devices "$devices" --listen "$listen" ${api_key:+--api-key "$api_key"} $sudo_args
}

menu() {
  while true; do
    echo
    echo -e "${C_CYAN}========================================${C_NC}"
    echo -e "${C_CYAN}   rtctl 远程终端控制 — 管理菜单（纯直连）${C_NC}"
    echo -e "${C_CYAN}   本机角色: 被控制(装agent) / 控制台(装clientd)${C_NC}"
    echo -e "${C_CYAN}========================================${C_NC}"
    echo -e "  ${C_GREEN}[1]${C_NC} 安装 agent ——【被控制的服务器】装这个（一台机器一个，装完等别人来控）"
    echo -e "  ${C_GREEN}[2]${C_NC} 安装 clientd ——【你操作的那台机器】装这个（AI Agent 通过它控制所有设备）"
    echo -e "  ${C_GREEN}[3]${C_NC} 查看状态（运行 + 开机自启）"
    echo -e "  ${C_GREEN}[4]${C_NC} 查看连接信息（复制 token / 设备清单 / 验证命令）"
    echo -e "  ${C_GREEN}[5]${C_NC} 升级到最新版"
    echo -e "  ${C_GREEN}[6]${C_NC} 卸载组件"
    echo -e "  ${C_GREEN}[7]${C_NC} 退出"
    read -rp "请选择 [7]: " choice
    case "${choice:-7}" in
      1) menu_agent ;;
      2) menu_clientd ;;
      3) cmd_status ;;
      4) cmd_info ;;
      5)
        read -rp "升级组件 [1] agent [2] clientd: " uc
        case "${uc:-1}" in 1) cmd_update agent ;; 2) cmd_update clientd ;; *) warn "跳过" ;; esac
        ;;
      6) cmd_uninstall ;;
      7) log "再见"; exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ---------- 入口 ----------

case "${1:-}" in
  agent)     shift; cmd_agent "$@" ;;
  clientd)   shift; cmd_clientd "$@" ;;
  status)    cmd_status ;;
  info)      cmd_info ;;
  uninstall) shift; cmd_uninstall "${1:-}" ;;
  update)    shift; cmd_update "${1:-}" ;;
  client)
    bin="$(get_bin "client-linux-$(get_arch)")"
    log "✔ client 就绪: $bin"
    log "  用法: $bin -server ws://<设备IP>:<端口>/ws exec -token <token> 'uptime'"
    ;;
  -h|--help)
    cat <<EOF
rtctl 一键部署（纯直连版）

用法:
  bash deploy.sh           交互菜单（安装 / 状态 / 升级 / 卸载）
  bash deploy.sh agent     --listen :8443 --id <ID> --token <token> [--tls-cert C --tls-key K]
  bash deploy.sh clientd   --devices <设备清单> [--listen 127.0.0.1:18080] [--api-key K]
  bash deploy.sh client    仅下载 client 二进制
  bash deploy.sh status    查看状态
  bash deploy.sh info      查看连接信息（token / 设备清单 / 验证命令）
  bash deploy.sh update    agent|clientd
  bash deploy.sh uninstall agent|clientd|all

二进制来源: 本地 ./bin 优先；缺省自动从 GitHub 下载（设 GH_BASE/GH_TOKEN 可指向私有源或镜像）
EOF
    ;;
  *) menu ;;
esac
