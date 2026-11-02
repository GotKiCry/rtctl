#!/bin/sh
# ============================================================================
# rtctl 一键安装与管理脚本（Linux）—— 安装后命令名 rt
#
#   自举（推荐先落盘再执行）：
#     curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh \
#       -o /tmp/rt-install.sh && sudo sh /tmp/rt-install.sh
#
#   便捷一行：
#     curl -fsSL https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh | sudo sh -s -- install --yes
#
#   无 sudo 的机器（用户级安装）：
#     sh /tmp/rt-install.sh --scope user
#
# 硬约束（改这个文件前先读）：
#   1. 纯 POSIX sh：只用 set -eu；禁止 pipefail / 数组 / [[ ]] / local；
#      探测性管道一律 || true。
#   2. 交互只从 fd 3（/dev/tty）读；curl | sh 时 stdin 是脚本本体，
#      绝不从 stdin 读一个字节（无 tty 时全部走默认值）。
#   3. 单文件 + 注册表（name<TAB>handler<TAB>risk<TAB>needs_root<TAB>desc）
#      驱动分发；未实现子命令统一 exit 11，未知子命令 exit 2。
#   4. 不读任何环境变量作为输入；固定 PATH；umask 077；外部命令先 command -v。
#   5. 原子替换：目标同目录 mktemp -> chmod/chown -> mv -f；SELinux 下 restorecon -F。
#   6. 凡写 agent.conf 必收尾 install -m 0600 -o rtctl -g rtctl；
#      /etc/rtctl 必须是 0750 root:rtctl 且先于 -init 创建。
# ============================================================================

set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
RT_VERSION='@@RTCTL_VERSION@@'
RT_SCHEMA=1
RT_NAME='rt'
RT_AGENT_NAME='rtctl-agent'
RT_SVC_NAME='rtctl-agent'
RT_RUN_USER='rtctl'
RT_RUN_GROUP='rtctl'
RT_BOOTSTRAP_URL='https://github.com/GotKiCry/rtctl/releases/latest/download/install.sh'
RT_REPO='GotKiCry/rtctl'
RT_RELEASES='https://github.com/GotKiCry/rtctl/releases'
RT_SUDOERS_SCRIPT='/etc/sudoers.d/rt-installer'
RT_SUDOERS_AGENT='/etc/sudoers.d/rtctl-agent'
RT_CA_IMPORT_DEBIAN='/usr/local/share/ca-certificates/rtctl-ca.crt'
RT_CA_IMPORT_RHEL='/etc/pki/ca-trust/source/anchors/rtctl-ca.crt'

# 退出码（主方案 §4.2）
EX_OK=0
EX_FAIL=1
EX_USAGE=2
EX_PLATFORM=3
EX_DOWNLOAD=4
EX_CHECKSUM=5
EX_NOROOT=6
EX_SERVICE=7
EX_CONFLICT=8
EX_HEALTH=9
EX_DOCTOR=10
EX_UNIMPL=11
EX_NOSECRET=12
EX_LOCK=75

# 随机端口范围与黑名单（用户拍板：5 位数端口 10000-65535）
RT_PORT_MIN=10000
RT_PORT_MAX=65535
RT_PORT_TRIES=50
RT_PORT_BLACKLIST='10000 11211 15672 16379 22222 27017 33060 50000 50070 61616
2049 2375 2376 3000 3306 4000 4369 5000 5432 5601 5672 5900 6379 7000 8000 8008
8080 8081 8088 8443 8888 9000 9090 9091 9092 9200 9300 9418 9999 10809 11212
27018 28017 50051 50052 25565'

# ---------------------------------------------------------------------------
# 输出与颜色（非终端不加色）
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    _rt_esc=$(printf '\033')
    C_ERR="$_rt_esc[31m"
    C_OK="$_rt_esc[32m"
    C_WARN="$_rt_esc[33m"
    C_INFO="$_rt_esc[36m"
    C_DIM="$_rt_esc[2m"
    C_RST="$_rt_esc[0m"
else
    C_ERR=''
    C_OK=''
    C_WARN=''
    C_INFO=''
    C_DIM=''
    C_RST=''
fi

hr() {
    printf '%s\n' "─────────────────────────────────────────────────────────────"
}

say() {
    if [ "$RT_QUIET" = 1 ]; then return 0; fi
    printf '%s\n' "$*"
}

info() {
    if [ "$RT_QUIET" = 1 ]; then return 0; fi
    printf '%s%s%s\n' "$C_INFO" "$*" "$C_RST"
}

ok() {
    if [ "$RT_QUIET" = 1 ]; then return 0; fi
    printf '%s✔%s %s\n' "$C_OK" "$C_RST" "$*"
}

warn() {
    printf '%s⚠ %s%s\n' "$C_WARN" "$*" "$C_RST" >&2
}

err() {
    printf '%s✘ %s%s\n' "$C_ERR" "$*" "$C_RST" >&2
}

hint() {
    if [ "$RT_QUIET" = 1 ]; then return 0; fi
    printf '%s   %s%s\n' "$C_DIM" "$*" "$C_RST"
}

die() {
    _rt_die_code=$1
    shift
    err "$*"
    exit "$_rt_die_code"
}

# ---------------------------------------------------------------------------
# 审计日志（脱敏，不记录原始 argv）
# ---------------------------------------------------------------------------
sanitize_text() {
    sed -e 's/[0-9a-fA-F]\{64\}/<redacted>/g' \
        -e 's/--token[= ][^ ]*/--token=<redacted>/g' \
        -e 's/BEGIN [A-Z ]*PRIVATE KEY/BEGIN <redacted>/g'
}

# assert_no_secret FILE —— 命中 64-hex / 私钥头 / token= 即返回 1
# 例外：`NAME_SHA256=<64hex>` 行是公开二进制的摘要，不是凭据。
assert_no_secret() {
    _rt_ans_file=${1:-}
    [ -n "$_rt_ans_file" ] || return 0
    [ -f "$_rt_ans_file" ] || return 0
    if grep -Ev '^[A-Z_]+_SHA256=[0-9a-f]{64}$' "$_rt_ans_file" 2>/dev/null \
        | grep -Eqi '[0-9a-f]{64}|BEGIN [A-Z ]*PRIVATE KEY|token[[:space:]]*[:=]'; then
        return 1
    fi
    return 0
}

log_line() {
    [ -n "${RT_LOG_FILE:-}" ] || return 0
    _rt_log_msg=$(printf '%s' "$*" | sanitize_text || true)
    _rt_log_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
    if [ -w "$RT_LOG_FILE" ] || { [ ! -e "$RT_LOG_FILE" ] && [ -w "$RT_LOG_DIR" ]; }; then
        printf '%s uid=%s euid=%s scope=%s %s\n' \
            "$_rt_log_ts" "$RT_UID" "$RT_EUID" "${RT_SCOPE:-unknown}" "$_rt_log_msg" \
            >>"$RT_LOG_FILE" 2>/dev/null || true
    fi
    if have logger; then logger -t "$RT_NAME" "$_rt_log_msg" 2>/dev/null || true; fi
}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
have() {
    command -v "$1" >/dev/null 2>&1
}

# 交互：只从 fd 3（/dev/tty）读，绝不碰 stdin
rt_open_tty() {
    RT_TTY=0
    if [ -r /dev/tty ]; then
        # bash 重定向从左到右处理：`exec 3</dev/tty 2>/dev/null` 在打开失败时会
        # 先把错误写到 stderr（此时 2>/dev/null 尚未生效），必须整块抑制。
        if { exec 3</dev/tty; } 2>/dev/null; then
            if [ -t 3 ]; then
                RT_TTY=1
            else
                { exec 3<&-; } 2>/dev/null || true
            fi
        fi
    fi
}

ask() {
    _rt_ask_p=$1
    _rt_ask_d=${2:-}
    _rt_ask_ans=''
    if [ "$RT_TTY" = 1 ]; then
        if [ -n "$_rt_ask_d" ]; then
            printf '%s [%s]: ' "$_rt_ask_p" "$_rt_ask_d" >&2
        else
            printf '%s: ' "$_rt_ask_p" >&2
        fi
        IFS= read -r _rt_ask_ans <&3 || _rt_ask_ans=''
        if [ -z "$_rt_ask_ans" ]; then _rt_ask_ans=$_rt_ask_d; fi
    else
        _rt_ask_ans=$_rt_ask_d
    fi
    printf '%s' "$_rt_ask_ans"
}

ask_yn() {
    _rt_yn_d=${2:-n}
    _rt_yn_a=$(ask "$1 (y/n)" "$_rt_yn_d")
    case "$_rt_yn_a" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

home_dir() {
    RT_HOME_DIR=''
    if have getent; then
        RT_HOME_DIR=$(getent passwd "$RT_UID" 2>/dev/null | awk -F: '{print $6}' || true)
    fi
    if [ -z "$RT_HOME_DIR" ] && [ -n "${HOME:-}" ]; then RT_HOME_DIR=$HOME; fi
    if [ -z "$RT_HOME_DIR" ]; then
        die "$EX_FAIL" "无法确定用户主目录（getent 与 HOME 均不可用）"
    fi
    return 0
}

# as_root CMD... —— euid=0 直接执行；否则按 --sudo 模式走 sudo
as_root() {
    if [ "$RT_EUID" = 0 ]; then
        "$@"
        return $?
    fi
    if ! have sudo; then
        die "$EX_NOROOT" "需要 root：请以 root 运行，或改用用户级安装：$RT_NAME install --scope user"
    fi
    if [ "$RT_SUDO_MODE" = nopasswd ]; then
        if sudo -n true >/dev/null 2>&1; then
            sudo -n -- "$@"
            return $?
        fi
    fi
    if [ "$RT_TTY" != 1 ] && ! sudo -n true >/dev/null 2>&1; then
        die "$EX_NOROOT" "需要 root，但当前没有终端可输入 sudo 密码（先执行 sudo -v，或以 root 运行）"
    fi
    sudo -- "$@"
}

# 以 root 身份执行一段 sh 代码（用于需要重定向/管道的场合）
as_root_sh() {
    as_root /bin/sh -c "$1"
}

# priv CMD... —— 按 scope 选择特权路径：system 走 as_root，user 直接执行
priv() {
    if [ "$RT_SCOPE" = user ] && [ "$RT_EUID" != 0 ]; then
        "$@"
        return $?
    fi
    as_root "$@"
}

# rt_tmpfile —— 结果放 RT_TMPFILE（必须在当前 shell 调用，die 才会真正中止脚本）
rt_tmpfile() {
    _rt_tf_dir=${TMPDIR:-/tmp}
    RT_TMPFILE=''
    RT_TMPFILE=$(mktemp "$_rt_tf_dir/.rt-tmp.XXXXXX" 2>/dev/null || true)
    if [ -z "$RT_TMPFILE" ]; then
        RT_TMPFILE=$(mktemp 2>/dev/null || true)
    fi
    if [ -z "$RT_TMPFILE" ]; then
        die "$EX_FAIL" "无法创建临时文件（检查 ${TMPDIR:-/tmp} 是否可写）"
    fi
    return 0
}

sed_escape_repl() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

require_root_or_die() {
    if [ "$RT_EUID" = 0 ]; then return 0; fi
    if [ "$RT_SUDO_MODE" = nopasswd ] && have sudo && sudo -n true >/dev/null 2>&1; then return 0; fi
    if [ "$RT_TTY" = 1 ] && have sudo; then return 0; fi
    die "$EX_NOROOT" "需要 root：sudo $RT_NAME $RT_CMD${RT_SUB:+ $RT_SUB}"
}

sha256_of() {
    _rt_sha_f=$1
    if have sha256sum; then
        sha256sum "$_rt_sha_f" 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if have shasum; then
        shasum -a 256 "$_rt_sha_f" 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if have openssl; then
        openssl dgst -sha256 "$_rt_sha_f" 2>/dev/null | awk '{print $NF}'
        return 0
    fi
    return 1
}

sha256_stdin() {
    if have sha256sum; then
        sha256sum 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if have shasum; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
        return 0
    fi
    if have openssl; then
        openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
        return 0
    fi
    return 1
}

fingerprint_of() {
    _rt_fp=$(printf '%s' "$1" | sha256_stdin || true)
    printf '%s' "$_rt_fp" | cut -c1-8 2>/dev/null || printf '????????'
}

mask_token() {
    _rt_mt=$1
    _rt_len=${#_rt_mt}
    if [ "$_rt_len" -le 8 ]; then
        printf '********'
        return 0
    fi
    printf '%s…%s' "$(printf '%s' "$_rt_mt" | cut -c1-4)" "$(printf '%s' "$_rt_mt" | cut -c"$((_rt_len - 3))-$_rt_len")"
}

check_elf() {
    _rt_elf=$1
    _rt_magic=$(od -An -c -N4 "$_rt_elf" 2>/dev/null | sed 's/[^0-9A-Za-z]//g' || true)
    [ "$_rt_magic" = '177ELF' ]
}

selinux_enabled() {
    [ -d /sys/fs/selinux ]
}

selinux_restorecon() {
    _rt_rc_path=$1
    if selinux_enabled && have restorecon; then
        restorecon -F "$_rt_rc_path" >/dev/null 2>&1 || true
    fi
}

# 原子落盘：目标同目录 mktemp -> chmod/chown -> mv -f
atomic_put() {
    _rt_ap_src=$1
    _rt_ap_dst=$2
    _rt_ap_mode=$3
    _rt_ap_owner=${4:-}
    _rt_ap_dir=$(dirname "$_rt_ap_dst")
    priv mkdir -p "$_rt_ap_dir" || return 1
    _rt_ap_tmp=$(priv mktemp "$_rt_ap_dir/.rt.XXXXXX") || return 1
    if ! priv cp "$_rt_ap_src" "$_rt_ap_tmp"; then
        priv rm -f "$_rt_ap_tmp" 2>/dev/null || true
        return 1
    fi
    priv chmod "$_rt_ap_mode" "$_rt_ap_tmp" || true
    if [ -n "$_rt_ap_owner" ]; then
        priv chown "$_rt_ap_owner" "$_rt_ap_tmp" || true
    fi
    selinux_restorecon "$_rt_ap_tmp"
    if ! priv mv -f "$_rt_ap_tmp" "$_rt_ap_dst"; then
        priv rm -f "$_rt_ap_tmp" 2>/dev/null || true
        return 1
    fi
    selinux_restorecon "$_rt_ap_dst"
    return 0
}

# ---------------------------------------------------------------------------
# 状态文件（唯一事实源；绝不 source，按 key 读取）
# ---------------------------------------------------------------------------
state_get() {
    _rt_sg_key=$1
    _rt_sg_val=''
    if [ -f "$RT_STATE_FILE" ]; then
        _rt_sg_val=$(sed -n "s/^${_rt_sg_key}=//p" "$RT_STATE_FILE" 2>/dev/null | head -n1 || true)
    fi
    printf '%s' "$_rt_sg_val"
}

state_write() {
    priv mkdir -p "$RT_STATE_DIR" 2>/dev/null || true
    rt_tmpfile
    _rt_sw_tmp=$RT_TMPFILE
    {
        printf 'RTCTL_SCHEMA=%s\n' "$RT_SCHEMA"
        printf 'SCRIPT_VERSION=%s\n' "$RT_VERSION"
        printf 'SCOPE=%s\n' "$RT_SCOPE"
        printf 'INIT=%s\n' "$RT_INIT"
        printf 'UNIT=%s\n' "$RT_UNIT"
        printf 'BIN_DIR=%s\n' "$RT_BIN_DIR"
        printf 'BIN_AGENT=%s\n' "$RT_BIN_AGENT"
        printf 'BIN_CLIENT=%s\n' "$RT_BIN_CLIENT"
        printf 'CONF=%s\n' "$RT_CONF"
        printf 'STATE_DIR=%s\n' "$RT_STATE_DIR"
        printf 'RUN_USER=%s\n' "$RT_RUN_USER"
        printf 'RUN_GROUP=%s\n' "$RT_RUN_GROUP"
        printf 'LISTEN=%s\n' "${RT_LISTEN_STATE:-}"
        printf 'PORT=%s\n' "${RT_PORT_STATE:-}"
        printf 'WS_PATH=%s\n' "${RT_WS_PATH_STATE:-}"
        printf 'TLS_ENABLED=%s\n' "${RT_TLS_ENABLED:-false}"
        printf 'TLS_CERT=%s\n' "${RT_TLS_CERT_STATE:-}"
        printf 'ALLOW_SUDO=%s\n' "${RT_ALLOW_SUDO_STATE:-false}"
        printf 'PRINT_TOKEN_FLAG_SUPPORTED=%s\n' "${RT_CAP_PRINT_TOKEN:-false}"
        printf 'VERSION_FLAG_SUPPORTED=%s\n' "${RT_CAP_VERSION:-false}"
        printf 'WS_PATH_FLAG_SUPPORTED=%s\n' "${RT_CAP_WS_PATH:-false}"
        printf 'OPEN_FIREWALL_FLAG_SUPPORTED=%s\n' "${RT_CAP_OPEN_FIREWALL:-false}"
        printf 'FOREGROUND_FLAG_SUPPORTED=%s\n' "${RT_CAP_FOREGROUND:-false}"
        printf 'LOGS_FLAG_SUPPORTED=%s\n' "${RT_CAP_LOGS:-false}"
        printf 'LOG_SOURCE=%s\n' "${RT_LOG_SOURCE:-}"
        printf 'LOG_FILE=%s\n' "${RT_SVC_LOG:-}"
        printf 'PID_FILE=%s\n' "${RT_PID_FILE:-}"
        printf 'FW_BACKEND=%s\n' "${RT_FW_BACKEND:-}"
        printf 'FW_RULE=%s\n' "${RT_FW_RULE:-}"
        printf 'FW_UNDO=%s\n' "${RT_FW_UNDO:-}"
        printf 'FW_APPLIED=%s\n' "${RT_FW_APPLIED:-false}"
        printf 'AUTOSTART=%s\n' "${RT_AUTOSTART:-none}"
        printf 'AGENT_VERSION=%s\n' "${RT_AGENT_VERSION:-unknown}"
        printf 'BINARY_SHA256=%s\n' "${RT_AGENT_SHA256:-}"
        printf 'TOKEN_FP=%s\n' "${RT_TOKEN_FP:-}"
        printf 'INSTALLED_AT=%s\n' "${RT_INSTALLED_AT:-}"
        printf 'UPGRADED_AT=%s\n' "${RT_UPGRADED_AT:-}"
        printf 'LAST_UPGRADE_RESULT=%s\n' "${RT_LAST_UPGRADE_RESULT:-}"
        printf 'ROLLBACK_AT=%s\n' "${RT_ROLLBACK_AT:-}"
        printf 'ROLLBACK_FROM_VERSION=%s\n' "${RT_ROLLBACK_FROM_VERSION:-}"
        printf 'LAST_ERROR=%s\n' "${RT_LAST_ERROR:-}"
        printf 'PREV_BINARY=%s\n' "${RT_PREV_BINARY:-}"
    } >"$_rt_sw_tmp"
    if ! assert_no_secret "$_rt_sw_tmp"; then
        rm -f "$_rt_sw_tmp" 2>/dev/null || true
        die "$EX_FAIL" "状态文件含疑似凭据（assert_no_secret 命中），已中止写入"
    fi
    if [ "$RT_SCOPE" = system ]; then
        atomic_put "$_rt_sw_tmp" "$RT_STATE_FILE" 0644 root:root \
            || { rm -f "$_rt_sw_tmp" 2>/dev/null || true; die "$EX_FAIL" "写入状态文件失败：$RT_STATE_FILE"; }
    else
        atomic_put "$_rt_sw_tmp" "$RT_STATE_FILE" 0644 \
            || { rm -f "$_rt_sw_tmp" 2>/dev/null || true; die "$EX_FAIL" "写入状态文件失败：$RT_STATE_FILE"; }
    fi
    rm -f "$_rt_sw_tmp" 2>/dev/null || true
    return 0
}

# 从配置文件/状态文件刷新运行时变量（每个子命令入口调用）
load_state() {
    if [ ! -f "$RT_STATE_FILE" ]; then return 1; fi
    RT_SCOPE=$(state_get SCOPE)
    RT_INIT=$(state_get INIT)
    RT_UNIT=$(state_get UNIT)
    RT_BIN_DIR=$(state_get BIN_DIR)
    RT_BIN_AGENT=$(state_get BIN_AGENT)
    RT_BIN_CLIENT=$(state_get BIN_CLIENT)
    RT_CONF=$(state_get CONF)
    RT_STATE_DIR=$(state_get STATE_DIR)
    RT_RUN_USER=$(state_get RUN_USER)
    RT_RUN_GROUP=$(state_get RUN_GROUP)
    RT_LISTEN_STATE=$(state_get LISTEN)
    RT_PORT_STATE=$(state_get PORT)
    RT_WS_PATH_STATE=$(state_get WS_PATH)
    RT_TLS_ENABLED=$(state_get TLS_ENABLED)
    RT_TLS_CERT_STATE=$(state_get TLS_CERT)
    RT_TLS_KEY_STATE=$(conf_read_key tls_key)
    RT_ALLOW_SUDO_STATE=$(state_get ALLOW_SUDO)
    RT_CAP_PRINT_TOKEN=$(state_get PRINT_TOKEN_FLAG_SUPPORTED)
    RT_CAP_VERSION=$(state_get VERSION_FLAG_SUPPORTED)
    RT_CAP_WS_PATH=$(state_get WS_PATH_FLAG_SUPPORTED)
    RT_CAP_OPEN_FIREWALL=$(state_get OPEN_FIREWALL_FLAG_SUPPORTED)
    RT_CAP_FOREGROUND=$(state_get FOREGROUND_FLAG_SUPPORTED)
    RT_CAP_LOGS=$(state_get LOGS_FLAG_SUPPORTED)
    RT_LOG_SOURCE=$(state_get LOG_SOURCE)
    RT_SVC_LOG=$(state_get LOG_FILE)
    RT_PID_FILE=$(state_get PID_FILE)
    RT_FW_BACKEND=$(state_get FW_BACKEND)
    RT_FW_RULE=$(state_get FW_RULE)
    RT_FW_UNDO=$(state_get FW_UNDO)
    RT_FW_APPLIED=$(state_get FW_APPLIED)
    RT_AUTOSTART=$(state_get AUTOSTART)
    RT_AGENT_VERSION=$(state_get AGENT_VERSION)
    RT_AGENT_SHA256=$(state_get BINARY_SHA256)
    RT_TOKEN_FP=$(state_get TOKEN_FP)
    RT_INSTALLED_AT=$(state_get INSTALLED_AT)
    RT_PREV_BINARY=$(state_get PREV_BINARY)
    return 0
}

state_require() {
    if ! load_state; then
        die "$EX_CONFLICT" "未检测到安装（缺少 $RT_STATE_FILE）：请先执行 $RT_NAME install"
    fi
}

# 锁：mkdir 是原子的
lock_acquire() {
    priv mkdir -p "$RT_STATE_DIR" 2>/dev/null || die "$EX_FAIL" "无法创建状态目录：$RT_STATE_DIR"
    if ! priv mkdir "$RT_STATE_DIR/install.lock" 2>/dev/null; then
        die "$EX_LOCK" "另一个安装/升级正在进行（锁：$RT_STATE_DIR/install.lock）；若确认无进程，删除该目录后重试"
    fi
    RT_LOCKED=1
    trap 'lock_release' 0 1 2 15
}

lock_release() {
    if [ "${RT_LOCKED:-0}" = 1 ]; then
        priv rmdir "$RT_STATE_DIR/install.lock" >/dev/null 2>&1 || true
        RT_LOCKED=0
    fi
}

# ---------------------------------------------------------------------------
# 端口：随机 5 位端口 + 三路占用检测 + 黑名单
# ---------------------------------------------------------------------------
port_blacklisted() {
    for _rt_bl in $RT_PORT_BLACKLIST; do
        if [ "$_rt_bl" = "$1" ]; then return 0; fi
    done
    return 1
}

port_listening_proc() {
    [ -r /proc/net/tcp ] || return 1
    awk -v want="$1" '
        function hex2dec(h,   i, c, v, n) {
            n = 0
            for (i = 1; i <= length(h); i++) {
                c = tolower(substr(h, i, 1))
                v = index("0123456789abcdef", c) - 1
                if (v < 0) return -1
                n = n * 16 + v
            }
            return n
        }
        FNR > 1 && $4 == "0A" {
            split($2, a, ":")
            if (hex2dec(a[2]) == want) { found = 1 }
        }
        END { exit(found ? 0 : 1) }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

port_in_use() {
    _rt_piu=$1
    if have ss; then
        if ss -ltn 2>/dev/null | awk -v p="$_rt_piu" '{n=split($4,a,":"); if (n>=2 && a[n]==p) f=1} END {exit(f?0:1)}'; then
            return 0
        fi
    fi
    if have netstat; then
        if netstat -ltn 2>/dev/null | awk -v p="$_rt_piu" '{n=split($4,a,":"); if (n>=2 && a[n]==p) f=1} END {exit(f?0:1)}'; then
            return 0
        fi
    fi
    if port_listening_proc "$_rt_piu"; then return 0; fi
    return 1
}

rand_port() {
    _rt_rp=''
    if [ -r /dev/urandom ] && have od; then
        _rt_rp=$(od -An -N2 -tu2 </dev/urandom 2>/dev/null | tr -d ' ' || true)
    fi
    if [ -z "$_rt_rp" ] && have openssl; then
        _rt_rp=$(openssl rand -hex 2 2>/dev/null || true)
        if [ -n "$_rt_rp" ]; then
            _rt_rp=$(printf '%d' "0x$_rt_rp" 2>/dev/null || printf '')
        fi
    fi
    if [ -z "$_rt_rp" ] && have awk; then
        _rt_rp=$(awk 'BEGIN{srand(); printf "%d", int(rand()*65536)}')
    fi
    case "$_rt_rp" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%d' "$((RT_PORT_MIN + (_rt_rp % (RT_PORT_MAX - RT_PORT_MIN + 1))))"
}

# pick_port —— 结果放 RT_PORT_PICKED（必须在当前 shell 调用）
pick_port() {
    RT_PORT_PICKED=''
    if [ -n "$RT_PORT" ]; then
        case "$RT_PORT" in
            *[!0-9]*) die "$EX_USAGE" "--port 必须是数字：$RT_PORT" ;;
        esac
        if [ "$RT_PORT" -lt 1 ] || [ "$RT_PORT" -gt 65535 ]; then
            die "$EX_USAGE" "--port 必须在 1-65535 之间：$RT_PORT"
        fi
        if port_blacklisted "$RT_PORT"; then
            warn "端口 $RT_PORT 在常见服务黑名单里，确认无冲突再继续"
        fi
        if port_in_use "$RT_PORT"; then
            die "$EX_CONFLICT" "端口 $RT_PORT 已被占用（ss/netstat//proc/net/tcp 三路检测）"
        fi
        RT_PORT_PICKED=$RT_PORT
        return 0
    fi
    _rt_pp_tries=0
    while [ "$_rt_pp_tries" -lt "$RT_PORT_TRIES" ]; do
        _rt_pp_new=$(rand_port || true)
        if [ -n "$_rt_pp_new" ] && ! port_blacklisted "$_rt_pp_new" && ! port_in_use "$_rt_pp_new"; then
            RT_PORT_PICKED=$_rt_pp_new
            return 0
        fi
        _rt_pp_tries=$((_rt_pp_tries + 1))
    done
    die "$EX_FAIL" "连续 $RT_PORT_TRIES 次随机端口都冲突（黑名单或已占用），请用 --port N 显式指定"
}

port_from_listen() {
    printf '%s' "$1" | sed -e 's/^.*://' -e 's/[^0-9].*$//'
}

probe_host() {
    _rt_ph=$1
    case "$_rt_ph" in
        :*|0.0.0.0:*) printf '127.0.0.1'; return 0 ;;
        \[::\]:*|\[::1\]:*) printf '[::1]'; return 0 ;;
    esac
    _rt_ph_h=${_rt_ph%:*}
    case "$_rt_ph_h" in
        ''|0.0.0.0) printf '127.0.0.1' ;;
        '::'|'[::]') printf '[::1]' ;;
        *) printf '%s' "$_rt_ph_h" ;;
    esac
}

local_ips() {
    if have ip; then
        ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -n 3 || true
        return 0
    fi
    if have hostname; then
        hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -n 3 || true
        return 0
    fi
    printf '127.0.0.1\n'
}

# ---------------------------------------------------------------------------
# 能力探测（老二进制不认的 flag 绝不写进 unit，否则崩溃循环）
# ---------------------------------------------------------------------------
agent_cap() {
    _rt_cap_bin=$1
    _rt_cap_flag=$2
    [ -x "$_rt_cap_bin" ] || return 1
    if "$_rt_cap_bin" -h 2>&1 | grep -q -- "$_rt_cap_flag"; then
        return 0
    fi
    return 1
}

probe_agent_caps() {
    _rt_pac_bin=${1:-$RT_BIN_AGENT}
    RT_CAP_PRINT_TOKEN=false
    RT_CAP_VERSION=false
    RT_CAP_WS_PATH=false
    RT_CAP_OPEN_FIREWALL=false
    RT_CAP_FOREGROUND=false
    RT_CAP_LOGS=false
    if agent_cap "$_rt_pac_bin" '-print-token'; then RT_CAP_PRINT_TOKEN=true; fi
    if agent_cap "$_rt_pac_bin" '-version'; then RT_CAP_VERSION=true; fi
    if agent_cap "$_rt_pac_bin" '-ws-path'; then RT_CAP_WS_PATH=true; fi
    if agent_cap "$_rt_pac_bin" '-open-firewall'; then RT_CAP_OPEN_FIREWALL=true; fi
    if agent_cap "$_rt_pac_bin" '-foreground'; then RT_CAP_FOREGROUND=true; fi
    if agent_cap "$_rt_pac_bin" '-logs'; then RT_CAP_LOGS=true; fi
}

agent_version_of() {
    _rt_av_bin=$1
    _rt_av=''
    if [ -x "$_rt_av_bin" ] && agent_cap "$_rt_av_bin" '-version'; then
        _rt_av=$("$_rt_av_bin" -version 2>/dev/null | head -n1 | awk '{print $NF}' || true)
    fi
    if [ -z "$_rt_av" ]; then _rt_av='unknown'; fi
    printf '%s' "$_rt_av"
}

# ---------------------------------------------------------------------------
# 配置读写（agent.conf 的键：listen/id/token/tls_cert/tls_key/allow_sudo/ws_path）
# ---------------------------------------------------------------------------
conf_exists() {
    [ -f "$RT_CONF" ]
}

conf_read_key() {
    _rt_crk=$1
    _rt_crv=''
    _rt_crv=$(sed -n "s/^[[:space:]]*${_rt_crk}[[:space:]]*=[[:space:]]*//p" "$RT_CONF" 2>/dev/null | head -n1 || true)
    printf '%s' "$_rt_crv" | tr -d '\r'
}

# 改写单个 key：本地生成新内容 -> 同目录临时文件 -> mv 原子替换 -> 收尾 chmod/chown
conf_set_key() {
    _rt_csk_key=$1
    _rt_csk_val=$2
    [ -f "$RT_CONF" ] || die "$EX_CONFLICT" "配置文件不存在：$RT_CONF"
    _rt_csk_esc=$(sed_escape_repl "$_rt_csk_val")
    rt_tmpfile
    _rt_csk_new=$RT_TMPFILE
    if ! priv sed -e "s|^[[:space:]]*${_rt_csk_key}[[:space:]]*=.*|${_rt_csk_key} = ${_rt_csk_esc}|" \
        "$RT_CONF" >"$_rt_csk_new" 2>/dev/null; then
        rm -f "$_rt_csk_new" 2>/dev/null || true
        die "$EX_FAIL" "读取配置失败：$RT_CONF"
    fi
    if ! grep -q "^[[:space:]]*${_rt_csk_key}[[:space:]]*=" "$_rt_csk_new" 2>/dev/null; then
        printf '%s = %s\n' "$_rt_csk_key" "$_rt_csk_val" >>"$_rt_csk_new"
    fi
    if ! atomic_put "$_rt_csk_new" "$RT_CONF" 0600 "$RT_RUN_USER:$RT_RUN_GROUP"; then
        rm -f "$_rt_csk_new" 2>/dev/null || true
        die "$EX_FAIL" "写入配置失败：$RT_CONF"
    fi
    rm -f "$_rt_csk_new" 2>/dev/null || true
    conf_finish_perms "$RT_CONF"
}

# 凡写 agent.conf 必收尾（铁律 1）
conf_finish_perms() {
    _rt_cfp=$1
    if [ "$RT_SCOPE" = system ]; then
        priv chmod 0600 "$_rt_cfp" || true
        priv chown "$RT_RUN_USER:$RT_RUN_GROUP" "$_rt_cfp" || true
    else
        chmod 0600 "$_rt_cfp" || true
    fi
}
# ---------------------------------------------------------------------------
# TLS 材料（--tls-generate 自签 CA + 服务器证书）
# ---------------------------------------------------------------------------
tls_generate() {
    _rt_tg_dir=$1
    _rt_tg_cn=$2
    if ! have openssl; then
        die "$EX_FAIL" "openssl 不可用，无法生成自签证书；请用 --tls-cert/--tls-key 指定已有证书"
    fi
    _rt_tg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/.rt-tls.XXXXXX" 2>/dev/null || true)
    if [ -z "$_rt_tg_tmp" ]; then die "$EX_FAIL" "无法创建临时目录（生成证书用）"; fi
    _rt_tg_cnf="$_rt_tg_tmp/openssl.cnf"
    _rt_tg_san="DNS:$_rt_tg_cn,IP:127.0.0.1"
    for _rt_tg_ip in $(local_ips); do
        case "$_rt_tg_ip" in
            127.*) ;;
            *) _rt_tg_san="$_rt_tg_san,IP:$_rt_tg_ip" ;;
        esac
    done
    {
        printf '[req]\n'
        printf 'distinguished_name = dn\n'
        printf 'prompt = no\n'
        printf '[dn]\n'
        printf 'O = rtctl\n'
        printf '[v3_ca]\n'
        printf 'basicConstraints = critical,CA:TRUE\n'
        printf 'keyUsage = critical,keyCertSign,cRLSign\n'
        printf 'subjectKeyIdentifier = hash\n'
        printf '[v3_srv]\n'
        printf 'basicConstraints = CA:FALSE\n'
        printf 'keyUsage = critical,digitalSignature,keyEncipherment\n'
        printf 'extendedKeyUsage = serverAuth\n'
        printf 'subjectAltName = %s\n' "$_rt_tg_san"
    } >"$_rt_tg_cnf"
    if ! (cd "$_rt_tg_tmp" \
        && openssl req -x509 -newkey rsa:4096 -nodes -keyout ca.key -out ca.crt \
            -days 3650 -config "$_rt_tg_cnf" -extensions v3_ca -subj '/CN=rtctl-ca' >/dev/null 2>&1 \
        && openssl req -newkey rsa:4096 -nodes -keyout agent.key -out agent.csr \
            -config "$_rt_tg_cnf" -subj "/CN=$_rt_tg_cn" >/dev/null 2>&1 \
        && openssl x509 -req -in agent.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
            -out agent.crt -days 825 -extfile "$_rt_tg_cnf" -extensions v3_srv >/dev/null 2>&1); then
        rm -rf "$_rt_tg_tmp" 2>/dev/null || true
        die "$EX_FAIL" "openssl 生成证书失败（检查 openssl 版本与 /dev/urandom）"
    fi
    priv mkdir -p "$_rt_tg_dir" || die "$EX_FAIL" "无法创建 TLS 目录：$_rt_tg_dir"
    if [ "$RT_SCOPE" = system ]; then
        priv chmod 0750 "$_rt_tg_dir" || true
        priv chown root:"$RT_RUN_GROUP" "$_rt_tg_dir" || true
        atomic_put "$_rt_tg_tmp/ca.crt" "$_rt_tg_dir/ca.crt" 0644 root:root || die "$EX_FAIL" "写入 ca.crt 失败"
        atomic_put "$_rt_tg_tmp/ca.key" "$_rt_tg_dir/ca.key" 0640 root:"$RT_RUN_GROUP" || die "$EX_FAIL" "写入 ca.key 失败"
        atomic_put "$_rt_tg_tmp/agent.crt" "$_rt_tg_dir/agent.crt" 0644 root:root || die "$EX_FAIL" "写入 agent.crt 失败"
        atomic_put "$_rt_tg_tmp/agent.key" "$_rt_tg_dir/agent.key" 0640 root:"$RT_RUN_GROUP" || die "$EX_FAIL" "写入 agent.key 失败"
    else
        chmod 0700 "$_rt_tg_dir" || true
        atomic_put "$_rt_tg_tmp/ca.crt" "$_rt_tg_dir/ca.crt" 0600 || die "$EX_FAIL" "写入 ca.crt 失败"
        atomic_put "$_rt_tg_tmp/ca.key" "$_rt_tg_dir/ca.key" 0600 || die "$EX_FAIL" "写入 ca.key 失败"
        atomic_put "$_rt_tg_tmp/agent.crt" "$_rt_tg_dir/agent.crt" 0600 || die "$EX_FAIL" "写入 agent.crt 失败"
        atomic_put "$_rt_tg_tmp/agent.key" "$_rt_tg_dir/agent.key" 0600 || die "$EX_FAIL" "写入 agent.key 失败"
    fi
    rm -rf "$_rt_tg_tmp" 2>/dev/null || true
    ok "已生成自签证书：$_rt_tg_dir/agent.crt + agent.key（CA: $_rt_tg_dir/ca.crt）"
}

tls_verify_pair() {
    _rt_tv_cert=$1
    _rt_tv_key=$2
    [ -r "$_rt_tv_cert" ] || return 1
    [ -r "$_rt_tv_key" ] || return 1
    if ! have openssl; then return 0; fi
    _rt_tv_a=$(openssl x509 -noout -modulus -in "$_rt_tv_cert" 2>/dev/null | sha256_stdin || true)
    _rt_tv_b=$(openssl rsa -noout -modulus -in "$_rt_tv_key" 2>/dev/null | sha256_stdin || true)
    if [ -z "$_rt_tv_a" ] || [ -z "$_rt_tv_b" ]; then return 0; fi
    [ "$_rt_tv_a" = "$_rt_tv_b" ]
}

tls_ca_import_hint() {
    _rt_tci_ca=${1:-/etc/rtctl/tls/ca.crt}
    say ''
    info '── TLS 已启用：控制机必须先信任本机 CA，否则报 x509: unknown authority ──'
    hint "1) 把 CA 拷到控制机： scp root@<本机IP>:$_rt_tci_ca ."
    hint "2) Debian/Ubuntu 控制机："
    hint "   sudo cp rtctl-ca.crt $RT_CA_IMPORT_DEBIAN && sudo update-ca-certificates"
    hint "3) RHEL/CentOS/Rocky/Fedora 控制机："
    hint "   sudo cp rtctl-ca.crt $RT_CA_IMPORT_RHEL && sudo update-ca-trust"
    hint "4) Windows 控制机（管理员 PowerShell）："
    hint "   Import-Certificate -FilePath .\\rtctl-ca.crt -CertStoreLocation Cert:\\LocalMachine\\Root"
    hint "5) 连接示例（TLS 下不要用快捷入口，它会被强制补 ws://）："
    hint "   rtctl -server wss://<本机IP>:<端口>${RT_WS_PATH_STATE} exec -token <token> -c 'uptime'"
}

# ---------------------------------------------------------------------------
# 运行用户（系统级专用账户 rtctl，幂等）
# ---------------------------------------------------------------------------
run_user_exists() {
    id -u "$RT_RUN_USER" >/dev/null 2>&1
}

nologin_shell() {
    if [ -x /usr/sbin/nologin ]; then printf '/usr/sbin/nologin'; return 0; fi
    if [ -x /sbin/nologin ]; then printf '/sbin/nologin'; return 0; fi
    printf '/bin/false'
}

ensure_run_user() {
    [ "$RT_SCOPE" = system ] || return 0
    if run_user_exists; then
        ok "运行用户 $RT_RUN_USER 已存在（幂等跳过）"
    else
        _rt_eru_sh=$(nologin_shell)
        if have useradd; then
            priv useradd -r -M -d /nonexistent -s "$_rt_eru_sh" "$RT_RUN_USER" \
                || die "$EX_FAIL" "创建运行用户失败：useradd -r -M -d /nonexistent -s $_rt_eru_sh $RT_RUN_USER"
        elif have adduser; then
            priv adduser -S -D -H -s /sbin/nologin "$RT_RUN_USER" \
                || die "$EX_FAIL" "创建运行用户失败：adduser -S -D -H -s /sbin/nologin $RT_RUN_USER"
        else
            die "$EX_FAIL" "缺少 useradd/adduser，无法创建运行用户 $RT_RUN_USER"
        fi
        if ! run_user_exists; then
            die "$EX_FAIL" "创建运行用户 $RT_RUN_USER 后仍检测不到（id -u 失败）"
        fi
        ok "已创建运行用户 $RT_RUN_USER（无 home、不可登录）"
    fi
    if have getent && ! getent group "$RT_RUN_GROUP" >/dev/null 2>&1; then
        if have groupadd; then
            priv groupadd -r "$RT_RUN_GROUP" >/dev/null 2>&1 || true
            priv usermod -aG "$RT_RUN_GROUP" "$RT_RUN_USER" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# agent -init：配置的唯一生成者（脚本绝不自己造 token）
# ---------------------------------------------------------------------------
agent_init_config() {
    _rt_aic_listen=$1
    _rt_aic_id=$2
    _rt_aic_ws=$3
    _rt_aic_tls_cert=${4:-}
    _rt_aic_tls_key=${5:-}
    _rt_aic_allow_sudo=${6:-0}
    if conf_exists; then
        say "配置已存在，保留既有 token：$RT_CONF"
        hint "轮换 token：$RT_NAME token reset    （配置冲突码 exit 8）"
        return 0
    fi
    [ -x "$RT_BIN_AGENT" ] || die "$EX_FAIL" "agent 二进制不可执行：$RT_BIN_AGENT"
    _rt_aic_dir=$(dirname "$RT_CONF")
    if [ "$RT_SCOPE" = system ]; then
        priv install -d -m 0750 -o root -g "$RT_RUN_GROUP" "$_rt_aic_dir" \
            || die "$EX_FAIL" "创建配置目录失败：$_rt_aic_dir"
    else
        mkdir -p "$_rt_aic_dir" || die "$EX_FAIL" "创建配置目录失败：$_rt_aic_dir"
        chmod 0700 "$_rt_aic_dir" 2>/dev/null || true
    fi
    rt_tmpfile
    _rt_aic_err=$RT_TMPFILE
    set -- -init -config "$RT_CONF" -listen "$_rt_aic_listen" -id "$_rt_aic_id"
    if [ -n "$_rt_aic_ws" ] && [ "$RT_CAP_WS_PATH" = true ]; then
        set -- "$@" -ws-path "$_rt_aic_ws"
    fi
    if [ -n "$_rt_aic_tls_cert" ] && [ -n "$_rt_aic_tls_key" ]; then
        set -- "$@" -tls-cert "$_rt_aic_tls_cert" -tls-key "$_rt_aic_tls_key"
    fi
    if [ "$_rt_aic_allow_sudo" = 1 ]; then
        set -- "$@" -allow-sudo
    fi
    if ! priv "$RT_BIN_AGENT" "$@" >/dev/null 2>"$_rt_aic_err"; then
        err "agent -init 失败："
        sanitize_text <"$_rt_aic_err" >&2 || true
        rm -f "$_rt_aic_err" 2>/dev/null || true
        die "$EX_FAIL" "生成配置失败（$RT_CONF 未被创建）"
    fi
    if [ -s "$_rt_aic_err" ]; then
        sanitize_text <"$_rt_aic_err" | while IFS= read -r _rt_aic_line; do
            log_line "init stderr: $_rt_aic_line"
        done
    fi
    rm -f "$_rt_aic_err" 2>/dev/null || true
    [ -f "$RT_CONF" ] || die "$EX_FAIL" "agent -init 未生成配置文件：$RT_CONF"
    conf_finish_perms "$RT_CONF"
    ok "已生成配置：$RT_CONF（0600 $RT_RUN_USER:$RT_RUN_GROUP）"
    return 0
}

# ---------------------------------------------------------------------------
# 版本解析与下载（不调 GitHub API，避免 60 次/小时限流）
# ---------------------------------------------------------------------------
# resolve_release_tag —— 结果放 RT_TAG_OUT（必须在当前 shell 调用）
resolve_release_tag() {
    RT_TAG_OUT=''
    if [ -n "$RT_RELEASE" ]; then
        case "$RT_RELEASE" in
            v[0-9]*.[0-9]*.[0-9]*) ;;
            *) die "$EX_USAGE" "--release 必须是 vX.Y.Z 形式：$RT_RELEASE" ;;
        esac
        RT_TAG_OUT=$RT_RELEASE
        return 0
    fi
    _rt_rrt_loc=''
    if have curl; then
        _rt_rrt_loc=$(curl -fsSI --max-time 20 "$RT_RELEASES/latest" 2>/dev/null \
            | sed -n 's/^[Ll]ocation: //p' | tr -d '\r' | tail -n1 || true)
    fi
    if [ -z "$_rt_rrt_loc" ] && have wget; then
        _rt_rrt_loc=$(wget -qS --max-redirect=0 --spider "$RT_RELEASES/latest" 2>&1 \
            | sed -n 's/.*[Ll]ocation: //p' | tr -d '\r' | tail -n1 || true)
    fi
    if [ -z "$_rt_rrt_loc" ]; then
        die "$EX_DOWNLOAD" "无法解析最新版本（$RT_RELEASES/latest 无重定向）：请用 --release vX.Y.Z 指定"
    fi
    _rt_rrt_tag=${_rt_rrt_loc##*/}
    if ! printf '%s' "$_rt_rrt_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        die "$EX_DOWNLOAD" "版本标签不符合白名单（^v[0-9]+\\.[0-9]+\\.[0-9]+$）：$_rt_rrt_tag"
    fi
    RT_TAG_OUT=$_rt_rrt_tag
    return 0
}

# detect_arch —— 结果放 RT_ARCH_OUT；不支持的架构返回 1
detect_arch() {
    RT_ARCH_OUT=''
    _rt_da=$(uname -m 2>/dev/null || printf '')
    case "$_rt_da" in
        x86_64|amd64) RT_ARCH_OUT='amd64' ;;
        aarch64|arm64) RT_ARCH_OUT='arm64' ;;
        *) return 1 ;;
    esac
    return 0
}

dl_url() {
    _rt_du_url=$1
    _rt_du_dst=$2
    if have curl; then
        if [ -n "$RT_PROXY" ]; then
            curl -fsSL --connect-timeout 15 --max-time 600 -x "$RT_PROXY" -o "$_rt_du_dst" "$_rt_du_url"
        else
            curl -fsSL --connect-timeout 15 --max-time 600 -o "$_rt_du_dst" "$_rt_du_url"
        fi
        return $?
    fi
    if have wget; then
        if [ -n "$RT_PROXY" ]; then
            HTTPS_PROXY="$RT_PROXY" HTTP_PROXY="$RT_PROXY" wget -q -T 30 -O "$_rt_du_dst" "$_rt_du_url"
        else
            wget -q -T 30 -O "$_rt_du_dst" "$_rt_du_url"
        fi
        return $?
    fi
    die "$EX_DOWNLOAD" "缺少 curl 与 wget，无法下载（可手动放置二进制后用 --agent-src）"
}

sums_expected() {
    _rt_se_asset=$1
    _rt_se_sums=$2
    [ -f "$_rt_se_sums" ] || return 1
    tr -d '\r' <"$_rt_se_sums" | awk -v f="$_rt_se_asset" '$2 == f {print $1; exit}'
}

# 校验：0 通过；1 不匹配；2 清单无该项；3 无校验工具
verify_asset() {
    _rt_va_file=$1
    _rt_va_asset=$2
    _rt_va_sums=$3
    _rt_va_exp=$(sums_expected "$_rt_va_asset" "$_rt_va_sums" || true)
    if [ -z "$_rt_va_exp" ]; then return 2; fi
    _rt_va_act=$(sha256_of "$_rt_va_file" || true)
    if [ -z "$_rt_va_act" ]; then return 3; fi
    if [ "$_rt_va_exp" = "$_rt_va_act" ]; then return 0; fi
    printf '%s\n' "expected=$_rt_va_exp" "actual  =$_rt_va_act" >&2
    return 1
}

fetch_assets() {
    _rt_fa_tag=$1
    _rt_fa_arch=$2
    if [ -n "$RT_BASE_URL" ]; then
        _rt_fa_base=$RT_BASE_URL
    else
        _rt_fa_base="$RT_RELEASES/download/$_rt_fa_tag"
    fi
    _rt_fa_dir="$RT_STATE_DIR/dl.$$"
    priv mkdir -p "$_rt_fa_dir" 2>/dev/null || true
    chmod 0700 "$_rt_fa_dir" 2>/dev/null || true
    RT_DL_DIR=$_rt_fa_dir
    _rt_fa_sums="$_rt_fa_dir/SHA256SUMS.txt"
    say "下载校验清单：$_rt_fa_base/SHA256SUMS.txt"
    if ! dl_url "$_rt_fa_base/SHA256SUMS.txt" "$_rt_fa_sums"; then
        die "$EX_DOWNLOAD" "下载 SHA256SUMS.txt 失败：$_rt_fa_base/SHA256SUMS.txt"
    fi
    if [ ! -s "$_rt_fa_sums" ]; then
        die "$EX_DOWNLOAD" "SHA256SUMS.txt 为空（镜像/代理返回了错误页？）"
    fi
    _rt_fa_agent="$_rt_fa_dir/rtctl-agent-linux-$_rt_fa_arch"
    say "下载 agent：$_rt_fa_base/rtctl-agent-linux-$_rt_fa_arch"
    if ! dl_url "$_rt_fa_base/rtctl-agent-linux-$_rt_fa_arch" "$_rt_fa_agent"; then
        die "$EX_DOWNLOAD" "下载 agent 二进制失败（检查网络/代理 --proxy）"
    fi
    if ! check_elf "$_rt_fa_agent"; then
        die "$EX_CHECKSUM" "下载内容不是 ELF 二进制（可能拿到 HTML 错误页或错架构）"
    fi
    _rt_fa_rc=0
    verify_asset "$_rt_fa_agent" "rtctl-agent-linux-$_rt_fa_arch" "$_rt_fa_sums" || _rt_fa_rc=$?
    case "$_rt_fa_rc" in
        0) ok "agent SHA256 校验通过" ;;
        2) die "$EX_CHECKSUM" "校验清单中没有 rtctl-agent-linux-$_rt_fa_arch 的条目（禁止跳过校验）" ;;
        3) die "$EX_CHECKSUM" "缺少 sha256sum/shasum/openssl，无法校验（禁止跳过校验）" ;;
        *) die "$EX_CHECKSUM" "agent SHA256 校验失败（下载损坏或版本不匹配）" ;;
    esac
    RT_DL_AGENT=$_rt_fa_agent
    RT_DL_CLIENT=''
    _rt_fa_client="$_rt_fa_dir/rtctl-linux-$_rt_fa_arch"
    if dl_url "$_rt_fa_base/rtctl-linux-$_rt_fa_arch" "$_rt_fa_client" 2>/dev/null && check_elf "$_rt_fa_client"; then
        if verify_asset "$_rt_fa_client" "rtctl-linux-$_rt_fa_arch" "$_rt_fa_sums"; then
            RT_DL_CLIENT=$_rt_fa_client
            ok "客户端 rtctl 已下载并校验（用于本机自检探针）"
        else
            warn "客户端校验失败，跳过（不影响 agent 安装）"
        fi
    else
        warn "客户端 rtctl 下载失败，跳过（不影响 agent 安装；token reset 的双探针会降级）"
    fi
    RT_DL_SCRIPT=''
    _rt_fa_script="$_rt_fa_dir/install.sh"
    if dl_url "$_rt_fa_base/install.sh" "$_rt_fa_script" 2>/dev/null && [ -s "$_rt_fa_script" ]; then
        if verify_asset "$_rt_fa_script" "install.sh" "$_rt_fa_sums"; then
            RT_DL_SCRIPT=$_rt_fa_script
        else
            warn "install.sh 校验失败，改用当前脚本本体落盘"
        fi
    fi
    return 0
}

self_script_source() {
    if [ -f "$0" ] && [ -r "$0" ]; then
        printf '%s' "$0"
        return 0
    fi
    if [ -n "${RT_DL_SCRIPT:-}" ] && [ -s "$RT_DL_SCRIPT" ]; then
        printf '%s' "$RT_DL_SCRIPT"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 服务后端探测（不能只看 command -v systemctl）
# ---------------------------------------------------------------------------
detect_init() {
    if [ -n "$RT_INIT_FORCE" ]; then
        printf '%s' "$RT_INIT_FORCE"
        return 0
    fi
    if [ "$RT_SCOPE" = user ]; then
        if have systemctl && [ -d /run/systemd/system ]; then
            printf 'systemd'
            return 0
        fi
        printf 'nohup'
        return 0
    fi
    if [ -d /run/systemd/system ] && [ -r /proc/1/comm ] \
        && [ "$(tr -d '\n' </proc/1/comm 2>/dev/null || printf '')" = 'systemd' ]; then
        printf 'systemd'
        return 0
    fi
    if [ -d /etc/init.d ] && have rc-service; then
        printf 'openrc'
        return 0
    fi
    printf 'nohup'
}

systemctl_do() {
    if [ "$RT_SCOPE" = user ]; then
        if [ "$RT_EUID" = 0 ] && [ "$(id -un 2>/dev/null || printf '')" != "$RT_RUN_USER" ]; then
            _rt_sd_uid=$(id -u "$RT_RUN_USER" 2>/dev/null || printf '')
            if [ -n "$_rt_sd_uid" ]; then
                if have runuser; then
                    runuser -u "$RT_RUN_USER" -- env "XDG_RUNTIME_DIR=/run/user/$_rt_sd_uid" \
                        systemctl --user "$@"
                    return $?
                fi
                if have su; then
                    su -s /bin/sh "$RT_RUN_USER" -c "XDG_RUNTIME_DIR=/run/user/$_rt_sd_uid systemctl --user $*"
                    return $?
                fi
            fi
        fi
        systemctl --user "$@"
        return $?
    fi
    systemctl "$@"
}

unit_exists() {
    [ -f "$RT_UNIT" ]
}

render_unit() {
    _rt_ru_listen=${1:-$RT_LISTEN_STATE}
    _rt_ru_ws=${2:-$RT_WS_PATH_STATE}
    _rt_ru_allow_sudo=${3:-0}
    _rt_ru_extra=''
    if [ "$RT_CAP_PRINT_TOKEN" = true ]; then
        _rt_ru_extra="$_rt_ru_extra -print-token=false"
    fi
    if [ "$RT_CAP_OPEN_FIREWALL" = true ]; then
        _rt_ru_extra="$_rt_ru_extra -open-firewall=false"
    fi
    if [ "$RT_CAP_FOREGROUND" = true ]; then
        _rt_ru_extra="$_rt_ru_extra -foreground -log-file $RT_SVC_LOG"
    fi
    if [ -n "$_rt_ru_ws" ] && [ "$_rt_ru_ws" != '/ws' ] && [ "$RT_CAP_WS_PATH" = true ]; then
        _rt_ru_extra="$_rt_ru_extra -ws-path $_rt_ru_ws"
    fi
    _rt_ru_nnp='yes'
    if [ "$_rt_ru_allow_sudo" = 1 ]; then _rt_ru_nnp='no'; fi
    rt_tmpfile
    _rt_ru_tmp=$RT_TMPFILE
    {
        printf '# 由 %s %s 生成并托管；手工修改会在下次 install/upgrade 时被重写\n' "$RT_NAME" "$RT_VERSION"
        printf '[Unit]\n'
        printf 'Description=rtctl-agent remote terminal daemon\n'
        if [ "$RT_SCOPE" = user ]; then
            printf 'After=default.target\n'
        else
            printf 'After=network.target\n'
        fi
        printf 'StartLimitIntervalSec=60\n'
        printf 'StartLimitBurst=5\n'
        printf '\n[Service]\n'
        printf 'Type=simple\n'
        if [ "$RT_SCOPE" = system ]; then
            printf 'User=%s\n' "$RT_RUN_USER"
            printf 'Group=%s\n' "$RT_RUN_GROUP"
            printf 'SupplementaryGroups=\n'
            printf 'WorkingDirectory=/\n'
            printf 'Environment=HOME=%s\n' "$RT_STATE_DIR"
            printf 'Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
            printf 'ExecStart=%s -config %s%s\n' "$RT_BIN_AGENT" "$RT_CONF" "$_rt_ru_extra"
        else
            printf 'WorkingDirectory=%%h\n'
            printf 'Environment=HOME=%%h\n'
            printf 'Environment=PATH=%%h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
            printf 'ExecStart=%s%s\n' "$RT_BIN_AGENT" "$_rt_ru_extra"
        fi
        printf 'Restart=always\n'
        printf 'RestartSec=2\n'
        printf 'TimeoutStopSec=20\n'
        printf 'KillMode=control-group\n'
        printf 'KillSignal=SIGTERM\n'
        printf 'SendSIGKILL=yes\n'
        printf 'LimitNOFILE=65535\n'
        printf 'LimitCORE=0\n'
        printf 'NoNewPrivileges=%s\n' "$_rt_ru_nnp"
        printf 'SyslogIdentifier=rtctl-agent\n'
        printf 'StandardOutput=journal\n'
        printf 'StandardError=journal\n'
        printf '\n[Install]\n'
        if [ "$RT_SCOPE" = user ]; then
            printf 'WantedBy=default.target\n'
        else
            printf 'WantedBy=multi-user.target\n'
        fi
    } >"$_rt_ru_tmp"
    if [ "$RT_SCOPE" = system ]; then
        atomic_put "$_rt_ru_tmp" "$RT_UNIT" 0644 root:root || { rm -f "$_rt_ru_tmp"; die "$EX_FAIL" "写入 unit 失败：$RT_UNIT"; }
    else
        atomic_put "$_rt_ru_tmp" "$RT_UNIT" 0644 || { rm -f "$_rt_ru_tmp"; die "$EX_FAIL" "写入 unit 失败：$RT_UNIT"; }
    fi
    rm -f "$_rt_ru_tmp" 2>/dev/null || true
    ok "已渲染服务单元：$RT_UNIT（NoNewPrivileges=$_rt_ru_nnp${_rt_ru_extra}）"
    if [ "$RT_CAP_PRINT_TOKEN" != true ]; then
        warn "当前 agent 不支持 -print-token：unit 未传该 flag，启动块会把完整 token 打进 journald，建议尽快升级"
    fi
    if [ "$RT_CAP_OPEN_FIREWALL" != true ]; then
        warn "当前 agent 不支持 -open-firewall：unit 未传该 flag，agent 每次启动都会尝试放行防火墙"
    fi
    if [ -n "$_rt_ru_ws" ] && [ "$_rt_ru_ws" != '/ws' ] && [ "$RT_CAP_WS_PATH" != true ]; then
        warn "当前 agent 不支持 -ws-path，配置里的 ws_path=$_rt_ru_ws 会被忽略（实际仍是 /ws）"
    fi
}

render_openrc() {
    rt_tmpfile
    _rt_ro_tmp=$RT_TMPFILE
    _rt_ro_extra=''
    if [ "$RT_CAP_PRINT_TOKEN" = true ]; then _rt_ro_extra="$_rt_ro_extra -print-token=false"; fi
    if [ "$RT_CAP_OPEN_FIREWALL" = true ]; then _rt_ro_extra="$_rt_ro_extra -open-firewall=false"; fi
    if [ "$RT_CAP_FOREGROUND" = true ]; then _rt_ro_extra="$_rt_ro_extra -foreground -log-file $RT_SVC_LOG"; fi
    if [ -n "$RT_WS_PATH_STATE" ] && [ "$RT_WS_PATH_STATE" != '/ws' ] && [ "$RT_CAP_WS_PATH" = true ]; then
        _rt_ro_extra="$_rt_ro_extra -ws-path $RT_WS_PATH_STATE"
    fi
    {
        printf '#!/sbin/openrc-run\n'
        printf '# 由 %s %s 生成并托管\n' "$RT_NAME" "$RT_VERSION"
        printf 'name="rtctl-agent"\n'
        printf 'description="rtctl-agent remote terminal daemon"\n'
        printf 'command="%s"\n' "$RT_BIN_AGENT"
        printf 'command_args="-config %s%s"\n' "$RT_CONF" "$_rt_ro_extra"
        printf 'command_user="%s:%s"\n' "$RT_RUN_USER" "$RT_RUN_GROUP"
        printf 'command_background="yes"\n'
        printf 'pidfile="%s"\n' "$RT_PID_FILE"
        printf 'output_log="%s"\n' "$RT_SVC_LOG"
        printf 'error_log="%s"\n' "$RT_SVC_LOG"
        printf 'supervisor="supervise-daemon"\n'
        printf 'respawn_delay="2"\n'
        printf 'respawn_max="5"\n'
        printf 'retry="SIGTERM/20"\n'
        printf 'depend() { use net; after firewall; }\n'
        printf 'start_pre() {\n'
        printf '    checkpath -d -m 0750 -o %s:%s %s\n' "$RT_RUN_USER" "$RT_RUN_GROUP" "$RT_STATE_DIR"
        printf '    checkpath -f -m 0640 -o %s:%s %s\n' "$RT_RUN_USER" "$RT_RUN_GROUP" "$RT_SVC_LOG"
        printf '}\n'
    } >"$_rt_ro_tmp"
    atomic_put "$_rt_ro_tmp" "/etc/init.d/rtctl-agent" 0755 root:root \
        || { rm -f "$_rt_ro_tmp"; die "$EX_FAIL" "写入 OpenRC 脚本失败：/etc/init.d/rtctl-agent"; }
    rm -f "$_rt_ro_tmp" 2>/dev/null || true
    ok "已渲染 OpenRC 服务：/etc/init.d/rtctl-agent"
}

install_service_unit() {
    case "$RT_INIT" in
        systemd) render_unit "$RT_LISTEN_STATE" "$RT_WS_PATH_STATE" "$RT_ALLOW_SUDO_STATE" ;;
        openrc) render_openrc ;;
        nohup) info "无 init 系统：使用 nohup+pidfile 托管（容器/WSL）" ;;
        *) die "$EX_FAIL" "未知服务后端：$RT_INIT" ;;
    esac
    RT_LOG_SOURCE='journald'
    if [ "$RT_INIT" = openrc ]; then RT_LOG_SOURCE=$RT_SVC_LOG; fi
    if [ "$RT_INIT" = nohup ]; then RT_LOG_SOURCE=$RT_SVC_LOG; fi
    if [ "$RT_CAP_FOREGROUND" = true ]; then RT_LOG_SOURCE=$RT_SVC_LOG; fi
}

svc_daemon_reload() {
    case "$RT_INIT" in
        systemd) systemctl_do daemon-reload >/dev/null 2>&1 || true ;;
        *) : ;;
    esac
}

svc_reset_failed() {
    if [ "$RT_INIT" = systemd ]; then
        systemctl_do reset-failed "$RT_SVC_NAME" >/dev/null 2>&1 || true
    fi
}

svc_pidfile_alive() {
    [ -n "${RT_PID_FILE:-}" ] && [ -f "$RT_PID_FILE" ] || return 1
    _rt_spa_pid=$(tr -dc '0-9' <"$RT_PID_FILE" 2>/dev/null || true)
    [ -n "$_rt_spa_pid" ] || return 1
    if [ -d /proc ]; then
        [ -d "/proc/$_rt_spa_pid" ] || return 1
    else
        kill -0 "$_rt_spa_pid" 2>/dev/null || return 1
    fi
    if [ -x "$RT_BIN_AGENT" ] && [ -r "/proc/$_rt_spa_pid/exe" ]; then
        _rt_spa_exe=$(readlink "/proc/$_rt_spa_pid/exe" 2>/dev/null || true)
        case "$_rt_spa_exe" in
            "$RT_BIN_AGENT"*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

svc_active() {
    case "$RT_INIT" in
        systemd) systemctl_do is-active --quiet "$RT_SVC_NAME" >/dev/null 2>&1 ;;
        openrc) rc-service "$RT_SVC_NAME" status >/dev/null 2>&1 ;;
        nohup) svc_pidfile_alive ;;
        *) return 1 ;;
    esac
}

svc_enabled() {
    case "$RT_INIT" in
        systemd) systemctl_do is-enabled --quiet "$RT_SVC_NAME" >/dev/null 2>&1 ;;
        openrc) rc-update show default 2>/dev/null | grep -q "^[[:space:]]*$RT_SVC_NAME" ;;
        nohup) [ -f /etc/cron.d/rtctl-agent ] ;;
        *) return 1 ;;
    esac
}

svc_start() {
    svc_reset_failed
    case "$RT_INIT" in
        systemd)
            if svc_active; then info "服务已在运行"; return 0; fi
            if ! systemctl_do start "$RT_SVC_NAME"; then return 1; fi
            _rt_ss_i=0
            while [ "$_rt_ss_i" -lt 15 ]; do
                if svc_active; then return 0; fi
                _rt_ss_i=$((_rt_ss_i + 1))
                sleep 1
            done
            return 1
            ;;
        openrc)
            if svc_active; then info "服务已在运行"; return 0; fi
            rc-service "$RT_SVC_NAME" start
            return $?
            ;;
        nohup)
            if svc_pidfile_alive; then info "服务已在运行（pidfile）"; return 0; fi
            svc_nohup_start
            return $?
            ;;
        *) return 1 ;;
    esac
}

svc_nohup_start() {
    [ -x "$RT_BIN_AGENT" ] || { err "agent 二进制不可执行：$RT_BIN_AGENT"; return 1; }
    priv mkdir -p "$RT_STATE_DIR" 2>/dev/null || true
    priv touch "$RT_SVC_LOG" 2>/dev/null || true
    if [ "$RT_SCOPE" = system ]; then
        priv chmod 0640 "$RT_SVC_LOG" 2>/dev/null || true
        priv chown "$RT_RUN_USER:$RT_RUN_GROUP" "$RT_SVC_LOG" 2>/dev/null || true
    fi
    _rt_ns_extra=''
    if [ "$RT_CAP_PRINT_TOKEN" = true ]; then _rt_ns_extra="$_rt_ns_extra -print-token=false"; fi
    if [ "$RT_CAP_OPEN_FIREWALL" = true ]; then _rt_ns_extra="$_rt_ns_extra -open-firewall=false"; fi
    if [ "$RT_CAP_FOREGROUND" = true ]; then _rt_ns_extra="$_rt_ns_extra -foreground -log-file $RT_SVC_LOG"; fi
    if [ -n "$RT_WS_PATH_STATE" ] && [ "$RT_WS_PATH_STATE" != '/ws' ] && [ "$RT_CAP_WS_PATH" = true ]; then
        _rt_ns_extra="$_rt_ns_extra -ws-path $RT_WS_PATH_STATE"
    fi
    if ! have setsid; then
        warn "缺少 setsid：agent 未脱离进程组，经 rtctl exec 触发的启动可能被一起杀掉"
    fi
    if [ "$RT_SCOPE" = system ]; then
        if have setsid; then
            priv sh -c "HOME='$RT_STATE_DIR' PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                setsid '$RT_BIN_AGENT' -config '$RT_CONF' $_rt_ns_extra >>'$RT_SVC_LOG' 2>&1 </dev/null & echo \$! >'$RT_PID_FILE'"
        else
            priv sh -c "HOME='$RT_STATE_DIR' PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
                nohup '$RT_BIN_AGENT' -config '$RT_CONF' $_rt_ns_extra >>'$RT_SVC_LOG' 2>&1 </dev/null & echo \$! >'$RT_PID_FILE'"
        fi
    else
        if have setsid; then
            HOME="$RT_STATE_DIR" setsid "$RT_BIN_AGENT" -config "$RT_CONF" $_rt_ns_extra >>"$RT_SVC_LOG" 2>&1 </dev/null &
        else
            HOME="$RT_STATE_DIR" nohup "$RT_BIN_AGENT" -config "$RT_CONF" $_rt_ns_extra >>"$RT_SVC_LOG" 2>&1 </dev/null &
        fi
        printf '%s\n' "$!" >"$RT_PID_FILE" 2>/dev/null || true
    fi
    _rt_ns_i=0
    while [ "$_rt_ns_i" -lt 15 ]; do
        if svc_pidfile_alive; then return 0; fi
        _rt_ns_i=$((_rt_ns_i + 1))
        sleep 1
    done
    return 1
}

svc_stop() {
    case "$RT_INIT" in
        systemd)
            if ! svc_active; then info "服务已停止"; return 0; fi
            systemctl_do stop "$RT_SVC_NAME" >/dev/null 2>&1 || true
            ;;
        openrc)
            if ! svc_active; then info "服务已停止"; return 0; fi
            rc-service "$RT_SVC_NAME" stop >/dev/null 2>&1 || true
            ;;
        nohup)
            if ! svc_pidfile_alive; then info "服务已停止"; return 0; fi
            _rt_st_pid=$(tr -dc '0-9' <"$RT_PID_FILE" 2>/dev/null || true)
            if [ -n "$_rt_st_pid" ]; then
                if [ "$RT_EUID" = 0 ]; then
                    kill -TERM "$_rt_st_pid" 2>/dev/null || true
                else
                    priv kill -TERM "$_rt_st_pid" 2>/dev/null || true
                fi
            fi
            ;;
    esac
    _rt_st_i=0
    while [ "$_rt_st_i" -lt 20 ]; do
        if ! svc_active; then
            if [ "$RT_INIT" = nohup ]; then priv rm -f "$RT_PID_FILE" 2>/dev/null || true; fi
            return 0
        fi
        _rt_st_i=$((_rt_st_i + 1))
        sleep 1
    done
    err "服务在 20 秒内未停止（不执行 kill -9，请人工确认）"
    return 1
}

svc_restart() {
    svc_reset_failed
    case "$RT_INIT" in
        systemd) systemctl_do restart "$RT_SVC_NAME" ;;
        openrc) rc-service "$RT_SVC_NAME" restart ;;
        nohup) svc_stop && svc_nohup_start ;;
        *) return 1 ;;
    esac
}

svc_enable() {
    case "$RT_INIT" in
        systemd) systemctl_do enable "$RT_SVC_NAME" >/dev/null 2>&1 ;;
        openrc) rc-update add "$RT_SVC_NAME" default >/dev/null 2>&1 ;;
        nohup)
            if have crontab || [ -d /etc/cron.d ]; then
                rt_tmpfile
                _rt_se_tmp=$RT_TMPFILE
                printf '# 由 %s 生成：容器/WSL 无 init 时的开机自启\n@reboot root %s -config %s >/dev/null 2>&1\n' \
                    "$RT_NAME" "$RT_BIN_AGENT" "$RT_CONF" >"$_rt_se_tmp"
                atomic_put "$_rt_se_tmp" "/etc/cron.d/rtctl-agent" 0644 root:root >/dev/null 2>&1 || true
                rm -f "$_rt_se_tmp" 2>/dev/null || true
                if [ -f /etc/cron.d/rtctl-agent ]; then
                    RT_AUTOSTART='cron@reboot'
                    return 0
                fi
            fi
            RT_AUTOSTART='none'
            warn "无 init 且无 crond：无法设置开机自启（容器请用 restart 策略，WSL 可在 /etc/wsl.conf 开 systemd=true）"
            return 0
            ;;
        *) return 1 ;;
    esac
}

svc_disable() {
    case "$RT_INIT" in
        systemd) systemctl_do disable "$RT_SVC_NAME" >/dev/null 2>&1 || true ;;
        openrc) rc-update del "$RT_SVC_NAME" default >/dev/null 2>&1 || true ;;
        nohup) priv rm -f /etc/cron.d/rtctl-agent >/dev/null 2>&1 || true ;;
        *) : ;;
    esac
    RT_AUTOSTART='none'
    return 0
}

svc_remove_unit() {
    case "$RT_INIT" in
        systemd)
            if [ -f "$RT_UNIT" ]; then priv rm -f "$RT_UNIT" || true; fi
            systemctl_do daemon-reload >/dev/null 2>&1 || true
            ;;
        openrc)
            priv rm -f /etc/init.d/rtctl-agent >/dev/null 2>&1 || true
            ;;
        nohup)
            priv rm -f /etc/cron.d/rtctl-agent >/dev/null 2>&1 || true
            ;;
        *) : ;;
    esac
    return 0
}

svc_logs() {
    _rt_sl_follow=${1:-0}
    # 新版 agent 内置日志查看器（自带脱敏与终端着色）：日志来源是文件时优先使用
    if [ "${RT_CAP_LOGS:-false}" = true ] && [ "$RT_LOG_SOURCE" = "$RT_SVC_LOG" ]; then
        set -- -logs -log-file "$RT_SVC_LOG" -lines 200
        if [ "$_rt_sl_follow" = 1 ]; then
            set -- "$@" -follow
        fi
        "$RT_BIN_AGENT" "$@"
        return $?
    fi
    if [ "$RT_INIT" = systemd ] && [ "${RT_CAP_FOREGROUND:-false}" != true ]; then
        if ! have journalctl; then die "$EX_FAIL" "缺少 journalctl，无法读取 journald 日志"; fi
        if [ "$_rt_sl_follow" = 1 ]; then
            journalctl -u "$RT_SVC_NAME" -n 200 -f
        else
            journalctl -u "$RT_SVC_NAME" -n 200 --no-pager
        fi
        return 0
    fi
    if [ ! -f "$RT_SVC_LOG" ]; then die "$EX_CONFLICT" "日志文件不存在：$RT_SVC_LOG"; fi
    if [ "$_rt_sl_follow" = 1 ]; then
        tail -n 200 -F "$RT_SVC_LOG"
    else
        tail -n 200 "$RT_SVC_LOG"
    fi
}

# ---------------------------------------------------------------------------
# 防火墙（唯一归属 install：放行一次并记录，便于卸载回滚）
# ---------------------------------------------------------------------------
fw_detect() {
    if have ufw && ufw status 2>/dev/null | grep -q '^Status:[[:space:]]*active'; then
        printf 'ufw'
        return 0
    fi
    if have firewall-cmd && firewall-cmd --state 2>/dev/null | grep -q 'running'; then
        printf 'firewalld'
        return 0
    fi
    if have iptables; then
        printf 'iptables'
        return 0
    fi
    printf 'none'
}

fw_can_modify() {
    if [ "$RT_EUID" = 0 ]; then
        return 0
    fi
    if ! have sudo || ! sudo -n true >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# 防火墙只使用 root 或免密 sudo，避免远程执行时在继承的 /dev/tty 上隐藏等待密码。
fw_priv() {
    if [ "$RT_EUID" = 0 ]; then
        "$@"
        return $?
    fi
    if ! fw_can_modify; then
        return 126
    fi
    sudo -n -- "$@"
}

fw_apply() {
    _rt_fa_port=$1
    RT_FW_APPLIED=false
    RT_FW_RULE=''
    RT_FW_UNDO=''
    if ! fw_can_modify; then
        RT_FW_BACKEND='none'
        hint "无 root/可用 sudo，跳过防火墙修改，仅检查 $_rt_fa_port/tcp 是否可连通"
        return 0
    fi
    _rt_fa_backend=$(fw_detect)
    RT_FW_BACKEND=$_rt_fa_backend
    case "$_rt_fa_backend" in
        ufw)
            if fw_priv ufw allow "$_rt_fa_port/tcp" comment 'rtctl' >/dev/null 2>&1 \
                || fw_priv ufw allow "$_rt_fa_port/tcp" >/dev/null 2>&1; then
                RT_FW_APPLIED=true
                RT_FW_RULE="allow $_rt_fa_port/tcp"
                RT_FW_UNDO="ufw delete allow $_rt_fa_port/tcp"
                ok "防火墙已放行 $_rt_fa_port/tcp（ufw）"
            else
                warn "ufw 放行失败（需要 root；非交互安装仅尝试免密 sudo），请手工执行：sudo ufw allow $_rt_fa_port/tcp"
            fi
            ;;
        firewalld)
            if fw_priv firewall-cmd --permanent --add-port="$_rt_fa_port/tcp" >/dev/null 2>&1 \
                && fw_priv firewall-cmd --reload >/dev/null 2>&1; then
                RT_FW_APPLIED=true
                RT_FW_RULE="port=$_rt_fa_port/tcp"
                RT_FW_UNDO="firewall-cmd --permanent --remove-port=$_rt_fa_port/tcp && firewall-cmd --reload"
                ok "防火墙已放行 $_rt_fa_port/tcp（firewalld）"
            else
                warn "firewalld 放行失败（需要 root；非交互安装仅尝试免密 sudo），请手工执行：sudo firewall-cmd --permanent --add-port=$_rt_fa_port/tcp && sudo firewall-cmd --reload"
            fi
            ;;
        iptables)
            _rt_fa_ok=0
            if fw_priv iptables -I INPUT -p tcp --dport "$_rt_fa_port" -m comment --comment rtctl -j ACCEPT >/dev/null 2>&1; then
                _rt_fa_ok=1
            fi
            if have ip6tables; then
                fw_priv ip6tables -I INPUT -p tcp --dport "$_rt_fa_port" -m comment --comment rtctl -j ACCEPT >/dev/null 2>&1 || true
            fi
            if [ "$_rt_fa_ok" = 1 ]; then
                RT_FW_APPLIED=true
                RT_FW_RULE="INPUT -p tcp --dport $_rt_fa_port -m comment --comment rtctl -j ACCEPT"
                RT_FW_UNDO="iptables -D INPUT -p tcp --dport $_rt_fa_port -m comment --comment rtctl -j ACCEPT"
                ok "防火墙已放行 $_rt_fa_port/tcp（iptables）"
                warn "iptables 规则重启后不保留：请执行 netfilter-persistent save 或改用 ufw/firewalld"
            else
                warn "iptables 放行失败（需要 root；非交互安装仅尝试免密 sudo），请手工执行：sudo iptables -I INPUT -p tcp --dport $_rt_fa_port -j ACCEPT"
            fi
            ;;
        *)
            warn "未检测到 ufw/firewalld/iptables，跳过放行；若在外网请自行放行 $_rt_fa_port/tcp"
            ;;
    esac
    if [ -n "$RT_ALLOW_FROM" ]; then
        hint "限源提示（--allow-from $RT_ALLOW_FROM）：请用防火墙/安全组把 $_rt_fa_port/tcp 限制到该网段"
    fi
    return 0
}

fw_revoke() {
    _rt_fr_backend=${RT_FW_BACKEND:-$(state_get FW_BACKEND)}
    _rt_fr_applied=${RT_FW_APPLIED:-$(state_get FW_APPLIED)}
    _rt_fr_port=${RT_PORT_STATE:-$(state_get PORT)}
    [ -n "$_rt_fr_port" ] || return 0
    if [ "$_rt_fr_applied" != true ]; then
        hint "安装时未成功放行防火墙规则，跳过撤销"
        return 0
    fi
    case "$_rt_fr_backend" in
        ufw)
            if fw_priv ufw --force delete allow "$_rt_fr_port/tcp" >/dev/null 2>&1; then
                ok "已撤销 ufw 规则：allow $_rt_fr_port/tcp"
            else
                warn "ufw 规则撤销失败，请手工执行：sudo ufw delete allow $_rt_fr_port/tcp"
            fi
            ;;
        firewalld)
            if fw_priv firewall-cmd --permanent --remove-port="$_rt_fr_port/tcp" >/dev/null 2>&1 \
                && fw_priv firewall-cmd --reload >/dev/null 2>&1; then
                ok "已撤销 firewalld 端口：$_rt_fr_port/tcp"
            else
                warn "firewalld 撤销失败，请手工执行：sudo firewall-cmd --permanent --remove-port=$_rt_fr_port/tcp && sudo firewall-cmd --reload"
            fi
            ;;
        iptables)
            _rt_fr_i=0
            while [ "$_rt_fr_i" -lt 5 ]; do
                if fw_priv iptables -D INPUT -p tcp --dport "$_rt_fr_port" -m comment --comment rtctl -j ACCEPT >/dev/null 2>&1; then
                    _rt_fr_i=$((_rt_fr_i + 1))
                else
                    break
                fi
            done
            if have ip6tables; then
                fw_priv ip6tables -D INPUT -p tcp --dport "$_rt_fr_port" -m comment --comment rtctl -j ACCEPT >/dev/null 2>&1 || true
            fi
            ok "已撤销 iptables 规则（带 comment rtctl 的才删）"
            ;;
        *)
            hint "无防火墙后端记录，跳过撤销"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# 健康检查（/healthz；探活地址从 listen 推导）
# ---------------------------------------------------------------------------
health_check() {
    _rt_hc_listen=${1:-$RT_LISTEN_STATE}
    _rt_hc_port=$(port_from_listen "$_rt_hc_listen")
    [ -n "$_rt_hc_port" ] || _rt_hc_port=$RT_PORT_STATE
    _rt_hc_host=$(probe_host "$_rt_hc_listen")
    _rt_hc_scheme='http'
    _rt_hc_insecure=''
    if [ "${RT_TLS_ENABLED:-false}" = true ]; then
        _rt_hc_scheme='https'
        _rt_hc_insecure='-k'
    fi
    _rt_hc_url="$_rt_hc_scheme://$_rt_hc_host:$_rt_hc_port/healthz"
    _rt_hc_i=0
    while [ "$_rt_hc_i" -lt 10 ]; do
        if have curl; then
            if curl -fsS $_rt_hc_insecure --max-time 2 "$_rt_hc_url" >/dev/null 2>&1; then
                return 0
            fi
        elif have wget; then
            if [ "$_rt_hc_scheme" = https ]; then
                if wget -q --no-check-certificate -T 2 -O /dev/null "$_rt_hc_url" 2>/dev/null; then return 0; fi
            else
                if wget -q -T 2 -O /dev/null "$_rt_hc_url" 2>/dev/null; then return 0; fi
            fi
        elif have nc; then
            if nc -z -w 2 "$_rt_hc_host" "$_rt_hc_port" >/dev/null 2>&1; then return 0; fi
        else
            if port_in_use "$_rt_hc_port"; then return 0; fi
        fi
        _rt_hc_i=$((_rt_hc_i + 1))
        sleep 1
    done
    return 1
}
# ---------------------------------------------------------------------------
# 引导块（install 结尾 / connect 重放）
# ---------------------------------------------------------------------------
print_sudo_guide() {
    say ''
    info '── 两层 sudo 授权（按需选择，风险自负）──'
    hint '第 1 层｜脚本层（安装器自己提权）：--sudo ask（默认，当场提示密码） / --sudo nopasswd（写 /etc/sudoers.d/rt-installer 免密）'
    hint '第 2 层｜agent 层（远程命令提权，两种形态）：'
    hint "  · 永久授权：$RT_NAME sudo enable  → 写 /etc/sudoers.d/rtctl-agent（rtctl ALL=(ALL) NOPASSWD: /bin/sh,/usr/bin/sh,/usr/bin/kill,/bin/kill）"
    hint "  · 临时授权：$RT_NAME sudo temp    → 不写 sudoers；控制端 rtctl exec -sudo 当场输入 root 密码，agent 用 sudo -S 从 stdin 读取"
    warn "永久授权 = 任何持有本机 token 的人都能直接获得 root；临时授权不落盘密码但需要每次输入"
    hint "查看当前状态：$RT_NAME sudo status    关闭永久授权：$RT_NAME sudo disable"
}

print_proxy_hint() {
    _rt_pph_domain=${1:-<你的域名>}
    _rt_pph_port=${RT_PORT_STATE:-}
    _rt_pph_path=${RT_WS_PATH_STATE:-/ws}
    say ''
    info '── 反向代理 / 路径前缀（agent 已支持 -ws-path）──'
    hint "生成完整模板：$RT_NAME proxy nginx   /   $RT_NAME proxy caddy"
    hint "nginx 关键片段（/rt/ 前缀）：location /rt/ { proxy_pass http://127.0.0.1:$_rt_pph_port/; }  +  WebSocket 升级头"
    hint "caddy 关键片段：$_rt_pph_domain { handle_path /rt/* { reverse_proxy 127.0.0.1:$_rt_pph_port } }"
    hint "路径前缀时把 agent 的 ws_path 设为 /rt$_rt_pph_path（$RT_NAME config set ws_path /rt$_rt_pph_path --restart）"
}

print_guidance() {
    _rt_pg_listen=${RT_LISTEN_STATE:-}
    _rt_pg_port=${RT_PORT_STATE:-}
    _rt_pg_ws=${RT_WS_PATH_STATE:-/ws}
    _rt_pg_tls=${RT_TLS_ENABLED:-false}
    _rt_pg_scheme='ws'
    if [ "$_rt_pg_tls" = true ]; then _rt_pg_scheme='wss'; fi
    _rt_pg_status='未运行'
    if svc_active; then _rt_pg_status='active'; fi
    _rt_pg_enabled='no'
    if svc_enabled; then _rt_pg_enabled='yes'; fi
    _rt_pg_token=$(token_value 2>/dev/null || true)
    hr
    info '── 下一步 ──'
    say "服务状态 : $_rt_pg_status (enabled=$_rt_pg_enabled)，后端=$RT_INIT，监听=$_rt_pg_listen"
    say "本机地址 : $(local_ips | tr '\n' ' ')"
    if [ -n "$_rt_pg_token" ]; then
        if [ -t 1 ] && [ "${RT_NO_PRINT_TOKEN:-0}" != 1 ] && [ "$RT_QUIET" != 1 ]; then
            say "设备 token: $_rt_pg_token"
            warn "token 即设备全部权限，勿贴群聊/工单/截图；如需隐藏下次用 --no-print-token"
        else
            say "设备 token: $(mask_token "$_rt_pg_token")  fingerprint=$(fingerprint_of "$_rt_pg_token")"
        fi
        hint "查看完整 token：$RT_NAME token show --reveal   （需交互终端）"
    else
        hint "查看 token：sudo $RT_NAME token show --reveal"
    fi
    say '控制机上执行（先下载客户端）：'
    hint "curl -fsSL $RT_RELEASES/latest/download/rtctl-linux-amd64 -o rtctl && chmod +x rtctl"
    _rt_pg_ip=$(local_ips | head -n1 || printf '127.0.0.1')
    if [ "$_rt_pg_tls" = true ]; then
        hint "rtctl -server wss://$_rt_pg_ip:$_rt_pg_port$_rt_pg_ws exec -token <token> -c 'uptime'"
    elif [ "$_rt_pg_ws" = '/ws' ]; then
        hint "rtctl $_rt_pg_ip:$_rt_pg_port <token> 'uptime'"
    else
        hint "rtctl -server ws://$_rt_pg_ip:$_rt_pg_port$_rt_pg_ws exec -token <token> -c 'uptime'"
    fi
    say "本机自检 : $RT_NAME doctor      实时日志 : $RT_NAME logs -f"
    say "改配置   : $RT_NAME config edit   卸载 : $RT_NAME uninstall"
    if [ "$_rt_pg_tls" = true ]; then
        say "TLS      : 已启用（$_rt_pg_scheme），证书 ${RT_TLS_CERT_STATE:-$(state_get TLS_CERT)}"
        tls_ca_import_hint "${RT_TLS_CERT_STATE%/*}/ca.crt"
    else
        warn "当前为明文 $_rt_pg_scheme：token 与命令在网络上明文传输，同网段可被截获"
        warn "补救：$RT_NAME install --tls-generate   （自签 CA + 服务器证书，并打印控制机导入 CA 的命令）"
        warn "      $RT_NAME config set tls_cert /etc/rtctl/tls/agent.crt 与 tls_key /etc/rtctl/tls/agent.key"
    fi
    if [ -n "${RT_PROXY_DOMAIN:-}" ]; then
        print_proxy_hint "$RT_PROXY_DOMAIN"
    else
        hint "需要反向代理/路径前缀？$RT_NAME proxy nginx|caddy 模板随时可生成"
    fi
    print_sudo_guide
    hr
}

# ---------------------------------------------------------------------------
# token 读取（只有一条完整取值路径：token show --reveal）
# ---------------------------------------------------------------------------
token_value() {
    [ -f "$RT_CONF" ] || return 1
    _rt_tv=$(conf_read_key token)
    [ -n "$_rt_tv" ] || return 1
    printf '%s' "$_rt_tv"
}

# ---------------------------------------------------------------------------
# install：8 步
# ---------------------------------------------------------------------------
install_one_binary() {
    _rt_iob_src=$1
    _rt_iob_dst=$2
    _rt_iob_owner=${3:-}
    if [ -f "$_rt_iob_dst" ]; then
        priv cp -p "$_rt_iob_dst" "$_rt_iob_dst.prev" >/dev/null 2>&1 || true
        priv chmod 0755 "$_rt_iob_dst.prev" >/dev/null 2>&1 || true
        RT_PREV_BINARY="$_rt_iob_dst.prev"
    fi
    if ! atomic_put "$_rt_iob_src" "$_rt_iob_dst" 0755 "$_rt_iob_owner"; then
        die "$EX_FAIL" "安装二进制失败：$_rt_iob_dst"
    fi
    return 0
}

cmd_install() {
    [ "$RT_SCOPE" = system ] && require_root_or_die
    if ! have curl && ! have wget; then
        die "$EX_DOWNLOAD" "缺少 curl 与 wget：请先安装其一（Debian: apt install curl；Alpine: apk add curl）"
    fi
    if ! have sha256sum && ! have shasum && ! have openssl; then
        die "$EX_CHECKSUM" "缺少 sha256sum/shasum/openssl：无法校验下载内容（禁止跳过校验）"
    fi
    if [ -n "$RT_PINNED" ]; then
        if [ ! -f "$0" ]; then
            die "$EX_USAGE" "--pinned-sha256 在管道执行（curl|sh）下无法自校验：请先落盘再执行"
        fi
        _rt_i_selfsha=$(sha256_of "$0" || true)
        if [ "$_rt_i_selfsha" != "$RT_PINNED" ]; then
            die "$EX_CHECKSUM" "install.sh 自身 sha256 不匹配：期望 $RT_PINNED，实际 $_rt_i_selfsha"
        fi
        ok "install.sh 自身 sha256 校验通过"
    fi
    lock_acquire

    # --- 步骤 1：环境预检 ---
    say "[1/8] 环境预检"
    if ! detect_arch; then
        die "$EX_PLATFORM" "不支持的架构：$(uname -m)（支持 x86_64/amd64 与 aarch64/arm64，可自行交叉编译后 --agent-src 安装）"
    fi
    RT_ARCH=$RT_ARCH_OUT
    if [ "$RT_SCOPE" = system ] && [ "$RT_EUID" != 0 ]; then
        say "  提权方式：sudo --sudo $RT_SUDO_MODE"
    fi
    if [ "$RT_SCOPE" = system ]; then
        priv mkdir -p "$RT_BIN_DIR" || die "$EX_FAIL" "无法创建 $RT_BIN_DIR"
        priv mkdir -p "$RT_LOG_DIR" 2>/dev/null || true
        priv chmod 0750 "$RT_LOG_DIR" 2>/dev/null || true
        priv chown root:root "$RT_LOG_DIR" 2>/dev/null || true
    else
        mkdir -p "$RT_BIN_DIR" || die "$EX_FAIL" "无法创建 $RT_BIN_DIR"
        mkdir -p "$RT_STATE_DIR" 2>/dev/null || true
    fi
    case ":$PATH:" in
        *":$RT_BIN_DIR:"*) : ;;
        *) warn "$RT_BIN_DIR 不在当前 PATH 中，安装后请用绝对路径或把它加入 PATH" ;;
    esac
    ok "平台 $(uname -s)/$RT_ARCH，scope=$RT_SCOPE"

    # --- 已装则先停服务、保留既有 token ---
    _rt_i_prev_scope=''
    if [ -f "$RT_STATE_FILE" ]; then
        _rt_i_prev_scope=$(sed -n 's/^SCOPE=//p' "$RT_STATE_FILE" 2>/dev/null | head -n1 || true)
        if [ -n "$_rt_i_prev_scope" ] && [ "$_rt_i_prev_scope" != "$RT_SCOPE" ]; then
            die "$EX_CONFLICT" "已安装为 scope=$_rt_i_prev_scope，与本次 scope=$RT_SCOPE 冲突；先 $RT_NAME uninstall 再改 scope"
        fi
        load_state
        say "检测到既有安装（$RT_STATE_FILE），执行幂等升级式安装"
        if svc_active; then
            svc_stop || die "$EX_SERVICE" "停止既有服务失败，已中止（避免半安装）"
        fi
    else
        RT_INIT=$(detect_init)
    fi
    [ -n "$RT_INIT" ] || RT_INIT=$(detect_init)

    # --- 步骤 2：解析版本 ---
    say "[2/8] 解析版本"
    resolve_release_tag
    RT_TAG=$RT_TAG_OUT
    ok "目标版本：$RT_TAG"

    # --- 步骤 3/4：下载与校验 ---
    say "[3/8] 下载二进制与校验清单"
    if [ -n "$RT_AGENT_SRC" ]; then
        [ -f "$RT_AGENT_SRC" ] || die "$EX_DOWNLOAD" "--agent-src 文件不存在：$RT_AGENT_SRC"
        RT_DL_AGENT=$RT_AGENT_SRC
        RT_DL_CLIENT=''
        RT_DL_SCRIPT=''
        RT_AGENT_SHA256=$(sha256_of "$RT_AGENT_SRC" || true)
        warn "使用本地二进制（--agent-src），跳过 SHA256 清单校验"
    else
        fetch_assets "$RT_TAG" "$RT_ARCH"
        RT_AGENT_SHA256=$(sha256_of "$RT_DL_AGENT" || true)
    fi
    say "[4/8] 校验 SHA256"
    if [ -z "$RT_AGENT_SHA256" ]; then
        die "$EX_CHECKSUM" "无法计算 agent 的 sha256（缺少校验工具）"
    fi
    _rt_i_sha16=$(printf '%s' "$RT_AGENT_SHA256" | cut -c1-16 || true)
    ok "agent sha256=${_rt_i_sha16}…"

    # --- 步骤 5/6：停旧服务 + 原子替换 ---
    say "[5/8] 落盘二进制与脚本（原子替换）"
    _rt_i_owner=''
    if [ "$RT_SCOPE" = system ]; then _rt_i_owner='root:root'; fi
    install_one_binary "$RT_DL_AGENT" "$RT_BIN_AGENT" "$_rt_i_owner"
    ok "agent 已安装：$RT_BIN_AGENT"
    if [ -n "$RT_DL_CLIENT" ]; then
        install_one_binary "$RT_DL_CLIENT" "$RT_BIN_CLIENT" "$_rt_i_owner"
        ok "客户端已安装：$RT_BIN_CLIENT（本机自检探针用）"
    elif [ -x "$RT_BIN_CLIENT" ]; then
        hint "沿用既有客户端：$RT_BIN_CLIENT"
    fi
    _rt_i_selfsrc=$(self_script_source || true)
    if [ -n "$_rt_i_selfsrc" ]; then
        install_one_binary "$_rt_i_selfsrc" "$RT_BIN_DIR/$RT_NAME" "$_rt_i_owner"
        ok "管理脚本已安装：$RT_BIN_DIR/$RT_NAME"
    else
        warn "无法确定脚本本体来源（管道执行且未取到 install.sh 资产）：请手动 cp 本脚本到 $RT_BIN_DIR/$RT_NAME"
    fi
    probe_agent_caps "$RT_BIN_AGENT"
    RT_AGENT_VERSION=$(agent_version_of "$RT_BIN_AGENT")

    # --- 步骤 7：运行用户、目录、配置、服务单元 ---
    say "[6/8] 创建运行用户与配置"
    ensure_run_user
    if [ "$RT_SCOPE" = system ]; then
        priv install -d -m 0750 -o root -g "$RT_RUN_GROUP" "$RT_CONF_DIR" \
            || die "$EX_FAIL" "创建 $RT_CONF_DIR 失败（必须先于 -init，否则 agent 的 MkdirAll 0700 会让 rtctl 读不到配置）"
        priv install -d -m 0755 -o root -g root "$RT_STATE_DIR" 2>/dev/null || true
    else
        mkdir -p "$RT_CONF_DIR" 2>/dev/null || true
        chmod 0700 "$RT_CONF_DIR" 2>/dev/null || true
    fi

    if conf_exists; then
        RT_LISTEN_STATE=$(conf_read_key listen)
        [ -n "$RT_LISTEN_STATE" ] || RT_LISTEN_STATE=":$RT_PORT_STATE"
        RT_PORT_STATE=$(port_from_listen "$RT_LISTEN_STATE")
        RT_WS_PATH_STATE=$(conf_read_key ws_path)
        [ -n "$RT_WS_PATH_STATE" ] || RT_WS_PATH_STATE='/ws'
        _rt_i_cert=$(conf_read_key tls_cert)
        if [ -n "$_rt_i_cert" ]; then RT_TLS_ENABLED=true; else RT_TLS_ENABLED=false; fi
        RT_TLS_CERT_STATE=$_rt_i_cert
        _rt_i_as=$(conf_read_key allow_sudo)
        case "$_rt_i_as" in true|1|yes|TRUE|True) RT_ALLOW_SUDO_STATE=1 ;; *) RT_ALLOW_SUDO_STATE=0 ;; esac
        say "  保留既有端口 $RT_PORT_STATE（端口只在首次安装生成，重启不变）"
        if [ -n "$RT_PORT" ] || [ -n "$RT_LISTEN" ]; then
            warn "既有配置里的 listen=$RT_LISTEN_STATE 生效，忽略本次 --port/--listen；改端口请用 $RT_NAME config set listen :<新端口> --restart"
        fi
    else
        pick_port
        _rt_i_port=$RT_PORT_PICKED
        if [ -n "$RT_LISTEN" ]; then
            case "$RT_LISTEN" in
                *:*) RT_LISTEN_STATE=$RT_LISTEN ;;
                *) RT_LISTEN_STATE="$RT_LISTEN:$_rt_i_port" ;;
            esac
        else
            RT_LISTEN_STATE=":$_rt_i_port"
        fi
        RT_PORT_STATE=$(port_from_listen "$RT_LISTEN_STATE")
        [ -n "$RT_PORT_STATE" ] || RT_PORT_STATE=$_rt_i_port
        RT_WS_PATH_STATE=${RT_WS_PATH:-/ws}
        case "$RT_WS_PATH_STATE" in
            /*) : ;;
            *) RT_WS_PATH_STATE="/$RT_WS_PATH_STATE" ;;
        esac
        RT_TLS_ENABLED=false
        RT_TLS_CERT_STATE=''
        RT_ALLOW_SUDO_STATE=0
        if [ "$RT_ALLOW_SUDO" = 1 ]; then RT_ALLOW_SUDO_STATE=1; fi
        ok "随机端口：$RT_PORT_STATE（ss/netstat//proc/net/tcp 三路检测已避开占用与黑名单）"
    fi

    if [ "$RT_TLS_GEN" = 1 ]; then
        _rt_i_cn=${RT_PROXY_DOMAIN:-$(hostname 2>/dev/null || printf 'rtctl')}
        tls_generate "$RT_TLS_DIR" "$_rt_i_cn"
        RT_TLS_CERT_STATE="$RT_TLS_DIR/agent.crt"
        RT_TLS_KEY_STATE="$RT_TLS_DIR/agent.key"
        RT_TLS_ENABLED=true
    elif [ -n "$RT_TLS_CERT" ]; then
        [ -f "$RT_TLS_CERT" ] || die "$EX_USAGE" "--tls-cert 文件不存在：$RT_TLS_CERT"
        [ -n "$RT_TLS_KEY" ] || die "$EX_USAGE" "--tls-cert 必须与 --tls-key 一起给出"
        [ -f "$RT_TLS_KEY" ] || die "$EX_USAGE" "--tls-key 文件不存在：$RT_TLS_KEY"
        if ! tls_verify_pair "$RT_TLS_CERT" "$RT_TLS_KEY"; then
            die "$EX_FAIL" "证书与私钥不匹配（modulus 哈希不一致）"
        fi
        RT_TLS_CERT_STATE=$RT_TLS_CERT
        RT_TLS_KEY_STATE=$RT_TLS_KEY
        RT_TLS_ENABLED=true
    fi

    _rt_i_id=${RT_ID:-$(hostname 2>/dev/null || printf 'node')}
    agent_init_config "$RT_LISTEN_STATE" "$_rt_i_id" "$RT_WS_PATH_STATE" \
        "$RT_TLS_CERT_STATE" "$RT_TLS_KEY_STATE" "$RT_ALLOW_SUDO_STATE"
    if conf_exists; then
        conf_finish_perms "$RT_CONF"
        _rt_i_cert_now=$(conf_read_key tls_cert)
        if [ -n "$RT_TLS_CERT_STATE" ] && [ "$_rt_i_cert_now" != "$RT_TLS_CERT_STATE" ]; then
            conf_set_key tls_cert "$RT_TLS_CERT_STATE"
            conf_set_key tls_key "$RT_TLS_KEY_STATE"
        fi
        if [ "$RT_ALLOW_SUDO_STATE" = 1 ]; then
            _rt_i_as_now=$(conf_read_key allow_sudo)
            case "$_rt_i_as_now" in true|TRUE|True|1) : ;; *) conf_set_key allow_sudo true ;; esac
        fi
    fi

    say "[7/8] 安装服务单元（后端：$RT_INIT）"
    if [ "$RT_INIT" = systemd ] && [ "$RT_SCOPE" = user ]; then
        priv mkdir -p "$(dirname "$RT_UNIT")" 2>/dev/null || true
    fi
    install_service_unit
    svc_daemon_reload

    # --- 步骤 8：防火墙、启动、健康检查 ---
    say "[8/8] 放行防火墙并启动"
    if [ "$RT_NO_FIREWALL" = 1 ]; then
        hint "--no-firewall：跳过放行（请自行确认 $RT_PORT_STATE/tcp 可达）"
        RT_FW_APPLIED=false
        RT_FW_BACKEND='none'
    elif [ "${RT_FW_APPLIED:-false}" = true ] && [ "${RT_FW_RULE:-}" != '' ] \
        && [ "$(state_get PORT)" = "$RT_PORT_STATE" ]; then
        hint "既有防火墙规则已覆盖 $RT_PORT_STATE/tcp，跳过重复放行"
    else
        fw_apply "$RT_PORT_STATE"
    fi
    if ! svc_start; then
        RT_LAST_ERROR='start failed'
        err "服务启动失败"
        hint "排错：$RT_NAME logs    状态：$RT_NAME status"
        state_write || true
        exit "$EX_SERVICE"
    fi
    if ! health_check "$RT_LISTEN_STATE"; then
        RT_LAST_ERROR='healthz failed'
        warn "健康检查未通过（$RT_LISTEN_STATE /healthz 无响应）"
        hint "排错：$RT_NAME logs ；也可能是防火墙/端口冲突"
        state_write || true
        exit "$EX_HEALTH"
    fi
    svc_enable >/dev/null 2>&1 || true
    RT_INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
    RT_TOKEN_FP=$(fingerprint_of "$(token_value 2>/dev/null || printf '')")
    RT_LAST_UPGRADE_RESULT='ok'
    state_write
    ok "安装完成：$RT_BIN_AGENT（$RT_AGENT_VERSION），监听 $RT_LISTEN_STATE"
    print_guidance
    log_line "action=install result=ok listen=$RT_LISTEN_STATE port=$RT_PORT_STATE tls=$RT_TLS_ENABLED allow_sudo=$RT_ALLOW_SUDO_STATE"
    return 0
}

# ---------------------------------------------------------------------------
# init / start / stop / restart / status / logs / enable / disable
# ---------------------------------------------------------------------------
cmd_init() {
    if ! load_state; then
        if [ ! -x "$RT_BIN_AGENT" ]; then
            die "$EX_CONFLICT" "未检测到 agent 二进制（$RT_BIN_AGENT）：请先执行 $RT_NAME install"
        fi
        RT_INIT=$(detect_init)
        RT_AGENT_VERSION=$(agent_version_of "$RT_BIN_AGENT")
    fi
    if conf_exists; then
        err "配置已存在：$RT_CONF"
        hint "重装请用 $RT_NAME install（保留 token）；轮换 token 用 $RT_NAME token reset"
        exit "$EX_CONFLICT"
    fi
    [ "$RT_SCOPE" = system ] && require_root_or_die
    probe_agent_caps "$RT_BIN_AGENT"
    pick_port
    _rt_ci_port=$RT_PORT_PICKED
    _rt_ci_listen=${RT_LISTEN:-":$_rt_ci_port"}
    case "$_rt_ci_listen" in
        *:*) : ;;
        *) _rt_ci_listen="$_rt_ci_listen:$_rt_ci_port" ;;
    esac
    _rt_ci_id=${RT_ID:-$(hostname 2>/dev/null || printf 'node')}
    agent_init_config "$_rt_ci_listen" "$_rt_ci_id" "${RT_WS_PATH:-/ws}" "$RT_TLS_CERT" "$RT_TLS_KEY" "${RT_ALLOW_SUDO:-0}"
    RT_LISTEN_STATE=$(conf_read_key listen)
    [ -n "$RT_LISTEN_STATE" ] || RT_LISTEN_STATE=$_rt_ci_listen
    RT_PORT_STATE=$(port_from_listen "$RT_LISTEN_STATE")
    RT_WS_PATH_STATE=$(conf_read_key ws_path)
    [ -n "$RT_WS_PATH_STATE" ] || RT_WS_PATH_STATE='/ws'
    RT_TOKEN_FP=$(fingerprint_of "$(token_value 2>/dev/null || printf '')")
    RT_INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
    if [ -f "$RT_STATE_FILE" ]; then
        state_write || true
    fi
    print_guidance
    return 0
}

cmd_start() {
    state_require
    svc_start || die "$EX_SERVICE" "启动失败，排错：$RT_NAME logs"
    ok "服务已启动"
    log_line 'action=start result=ok'
}

cmd_stop() {
    state_require
    svc_stop || die "$EX_SERVICE" "停止失败（未执行 kill -9，请人工确认）"
    ok "服务已停止（agent 退出码可能为 1，属正常：ServeStandalone 返回 ErrServerClosed）"
    log_line 'action=stop result=ok'
}

cmd_restart() {
    state_require
    svc_restart || die "$EX_SERVICE" "重启失败，排错：$RT_NAME logs"
    if ! health_check "$RT_LISTEN_STATE"; then
        die "$EX_HEALTH" "重启后健康检查未通过，排错：$RT_NAME logs"
    fi
    ok "服务已重启并通过健康检查"
    log_line 'action=restart result=ok'
}

cmd_status() {
    _rt_cs_have=0
    if load_state; then _rt_cs_have=1; fi
    if [ "$_rt_cs_have" = 0 ]; then
        RT_INIT=$(detect_init)
        say "未检测到安装状态文件（$RT_STATE_FILE）"
    fi
    hr
    say "脚本版本   : $RT_VERSION"
    say "scope      : ${RT_SCOPE:-unknown}"
    say "服务后端   : ${RT_INIT:-unknown}"
    say "服务状态   : $(if svc_active; then printf 'active'; else printf 'inactive'; fi)"
    say "开机自启   : $(if svc_enabled; then printf 'enabled'; else printf 'disabled'; fi)"
    say "监听       : ${RT_LISTEN_STATE:-unknown}（端口 ${RT_PORT_STATE:-unknown}，ws_path ${RT_WS_PATH_STATE:-/ws}）"
    say "agent 二进制: ${RT_BIN_AGENT:-unknown}（版本 ${RT_AGENT_VERSION:-unknown}）"
    say "配置文件   : ${RT_CONF:-unknown}"
    if [ -n "${RT_CONF:-}" ] && [ -f "$RT_CONF" ]; then
        say "配置权限   : $(priv stat -c '%a %U:%G' "$RT_CONF" 2>/dev/null || printf '?')"
    fi
    if [ -n "${RT_CONF_DIR:-}" ] && [ -d "$RT_CONF_DIR" ]; then
        say "配置目录   : $(priv stat -c '%a %U:%G' "$RT_CONF_DIR" 2>/dev/null || printf '?')"
    fi
    say "TLS        : ${RT_TLS_ENABLED:-unknown}"
    say "token 指纹 : ${RT_TOKEN_FP:-unknown}"
    say "安装时间   : ${RT_INSTALLED_AT:-unknown}"
    if [ -n "${RT_PORT_STATE:-}" ]; then
        if port_in_use "$RT_PORT_STATE"; then
            say "端口占用   : 已被监听（正常）"
        else
            say "端口占用   : 未监听（服务可能未运行）"
        fi
    fi
    if [ "$_rt_cs_have" = 1 ]; then
        if svc_active; then :; else
            hint "启动：$RT_NAME start   排错：$RT_NAME logs"
        fi
    else
        hint "安装：$RT_NAME install"
    fi
    if [ "$RT_VERBOSE" = 1 ] && [ -f "$RT_STATE_FILE" ]; then
        info "── 状态文件 $RT_STATE_FILE（已脱敏）──"
        sanitize_text <"$RT_STATE_FILE"
    fi
    hr
    return 0
}

cmd_logs() {
    state_require
    # 内置查看器自己脱敏：再走管道会把 stdout 变成非终端，颜色自动失效
    if [ "${RT_CAP_LOGS:-false}" = true ] && [ "$RT_LOG_SOURCE" = "$RT_SVC_LOG" ]; then
        svc_logs "${RT_FOLLOW:-0}"
    else
        svc_logs "${RT_FOLLOW:-0}" | sanitize_text
    fi
}

cmd_enable() {
    state_require
    if svc_enabled; then info "开机自启已启用（幂等）"; return 0; fi
    svc_enable || die "$EX_SERVICE" "启用开机自启失败"
    if [ "$RT_AUTOSTART" = none ]; then
        warn "当前环境无法设置开机自启（无 init 且无 crond）"
    else
        ok "开机自启已启用（$RT_AUTOSTART）"
    fi
    state_write || true
    log_line 'action=enable result=ok'
}

cmd_disable() {
    state_require
    if ! svc_enabled; then info "开机自启已禁用（幂等）"; return 0; fi
    svc_disable || die "$EX_SERVICE" "禁用开机自启失败"
    ok "开机自启已禁用"
    state_write || true
    log_line 'action=disable result=ok'
}

# ---------------------------------------------------------------------------
# upgrade：停 -> 原子替换 -> 起 -> 健康检查 -> 失败回滚
# ---------------------------------------------------------------------------
detach_run() {
    if [ "$RT_INIT" = systemd ] && have systemd-run; then
        if systemd-run --unit="rt-upgrade-$$" --collect --quiet -- "$@" >/dev/null 2>&1; then
            return 0
        fi
    fi
    if have setsid; then
        setsid "$@" >>"$RT_LOG_FILE" 2>&1 </dev/null &
        return 0
    fi
    nohup "$@" >>"$RT_LOG_FILE" 2>&1 </dev/null &
    return 0
}

cmd_upgrade() {
    state_require
    [ "$RT_SCOPE" = system ] && require_root_or_die
    if ! have curl && ! have wget; then die "$EX_DOWNLOAD" "缺少 curl 与 wget"; fi
    resolve_release_tag
    RT_TAG=$RT_TAG_OUT
    _rt_u_cur=${RT_AGENT_VERSION:-unknown}
    if [ "$RT_TAG" = "$_rt_u_cur" ] || [ "v$RT_TAG" = "$_rt_u_cur" ] || [ "$RT_TAG" = "v$_rt_u_cur" ]; then
        say "已是最新：$RT_TAG（当前 $_rt_u_cur）"
        return 0
    fi
    if [ "$RT_CHECK" = 1 ]; then
        say "可升级：$_rt_u_cur -> $RT_TAG"
        return 0
    fi
    if [ "${RT_DETACHED:-0}" != 1 ] && [ -f "$0" ]; then
        _rt_u_args="upgrade --detached --yes --release $RT_TAG --scope $RT_SCOPE"
        if [ -n "$RT_BASE_URL" ]; then _rt_u_args="$_rt_u_args --base-url $RT_BASE_URL"; fi
        if [ -n "$RT_PROXY" ]; then _rt_u_args="$_rt_u_args --proxy $RT_PROXY"; fi
        # shellcheck disable=SC2086
        detach_run /bin/sh "$0" $_rt_u_args || die "$EX_SERVICE" "无法脱离调用者执行升级"
        ok "升级已在后台脱离当前进程执行（避免经 rtctl exec 升级时把自己掐死）"
        say "查看进度：$RT_NAME logs    /    tail -f $RT_LOG_FILE"
        return 0
    fi
    lock_acquire
    if ! detect_arch; then
        die "$EX_PLATFORM" "不支持的架构：$(uname -m)"
    fi
    RT_ARCH=$RT_ARCH_OUT
    svc_stop || die "$EX_SERVICE" "停止服务失败，升级中止"
    fetch_assets "$RT_TAG" "$RT_ARCH"
    _rt_u_newsha=$(sha256_of "$RT_DL_AGENT" || true)
    if [ -f "$RT_BIN_AGENT" ]; then
        priv cp -p "$RT_BIN_AGENT" "$RT_BIN_AGENT.prev" || die "$EX_FAIL" "备份当前二进制失败"
        RT_PREV_BINARY="$RT_BIN_AGENT.prev"
    fi
    _rt_u_owner=''
    if [ "$RT_SCOPE" = system ]; then _rt_u_owner='root:root'; fi
    atomic_put "$RT_DL_AGENT" "$RT_BIN_AGENT" 0755 "$_rt_u_owner" || die "$EX_FAIL" "替换二进制失败"
    if [ -n "$RT_DL_CLIENT" ]; then atomic_put "$RT_DL_CLIENT" "$RT_BIN_CLIENT" 0755 "$_rt_u_owner" || true; fi
    _rt_u_selfsrc=$(self_script_source || true)
    if [ -n "$_rt_u_selfsrc" ]; then atomic_put "$_rt_u_selfsrc" "$RT_BIN_DIR/$RT_NAME" 0755 "$_rt_u_owner" || true; fi
    probe_agent_caps "$RT_BIN_AGENT"
    RT_AGENT_VERSION=$(agent_version_of "$RT_BIN_AGENT")
    RT_AGENT_SHA256=$_rt_u_newsha
    if svc_start && health_check "$RT_LISTEN_STATE"; then
        RT_UPGRADED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
        RT_LAST_UPGRADE_RESULT='ok'
        state_write || true
        ok "升级完成：$RT_TAG"
        log_line "action=upgrade result=ok version=$RT_TAG"
        return 0
    fi
    warn "升级后健康检查失败，开始回滚"
    if [ -f "$RT_PREV_BINARY" ]; then
        atomic_put "$RT_PREV_BINARY" "$RT_BIN_AGENT" 0755 "$_rt_u_owner" || true
        RT_ROLLBACK_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
        RT_ROLLBACK_FROM_VERSION=$RT_TAG
        RT_LAST_UPGRADE_RESULT='rolled_back'
        RT_LAST_ERROR='health check failed after upgrade'
        svc_restart >/dev/null 2>&1 || true
        state_write || true
        log_line "action=upgrade result=rolled_back version=$RT_TAG"
        die "$EX_HEALTH" "升级失败，已回滚到上一版本（$RT_PREV_BINARY）；排错：$RT_NAME logs"
    fi
    RT_LAST_UPGRADE_RESULT='rollback_failed'
    RT_LAST_ERROR='no .prev binary to roll back to'
    state_write || true
    die "$EX_HEALTH" "升级失败且没有可回滚的 .prev 二进制；请用 --agent-src 手工恢复"
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
cmd_uninstall() {
    [ "$RT_SCOPE" = system ] && require_root_or_die
    if ! load_state; then
        RT_INIT=$(detect_init)
        warn "未检测到状态文件（$RT_STATE_FILE），按当前 scope 尽力清理"
    fi
    # 自删保护：先把自身 cp 到 $TMPDIR 再 exec
    if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")" = "$RT_BIN_DIR/$RT_NAME" ]; then
        _rt_un_self="${TMPDIR:-/tmp}/rt-uninstall.$$.sh"
        if cp "$0" "$_rt_un_self" 2>/dev/null; then
            chmod 0700 "$_rt_un_self" 2>/dev/null || true
            exec /bin/sh "$_rt_un_self" "$@"
        fi
        warn "无法把自身复制到 ${TMPDIR:-/tmp}，继续用当前进程执行（本次可完成，但脚本文件会被删除）"
    fi
    if [ "$RT_YES" != 1 ]; then
        say "将要移除：服务单元 / 二进制 / 防火墙规则（配置默认保留）"
        if [ "$RT_PURGE" = 1 ]; then warn "--purge：还会销毁 agent.conf（含 token）与状态目录、专用用户"; fi
        if ! ask_yn '确认卸载？' 'n'; then
            say '已取消'
            return 0
        fi
    fi
    say '[1/7] 停止服务'
    svc_stop || warn "停止服务未成功，继续卸载"
    if svc_active; then
        warn "服务仍处于 active，先 disable 再继续（避免自动重启）"
    fi
    say '[2/7] 关闭开机自启'
    svc_disable >/dev/null 2>&1 || true
    say '[3/7] 清理失败状态'
    svc_reset_failed
    say '[4/7] 删除服务单元'
    svc_remove_unit
    say '[5/7] 删除二进制'
    for _rt_un_f in "$RT_BIN_AGENT" "$RT_BIN_AGENT.prev" "$RT_BIN_CLIENT" "$RT_BIN_CLIENT.prev" "$RT_BIN_DIR/$RT_NAME"; do
        if [ -n "$_rt_un_f" ] && [ -e "$_rt_un_f" ]; then
            priv rm -f "$_rt_un_f" && hint "已删除 $_rt_un_f"
        fi
    done
    say '[6/7] 撤销防火墙规则'
    fw_revoke
    say '[7/7] 处理配置与状态'
    if [ "$RT_PURGE" = 1 ]; then
        if [ -f "$RT_CONF" ]; then
            if have shred; then priv shred -u "$RT_CONF" 2>/dev/null || priv rm -f "$RT_CONF"; else priv rm -f "$RT_CONF"; fi
        fi
        for _rt_un_b in "$RT_CONF_DIR"/agent.conf.bak-*; do
            [ -e "$_rt_un_b" ] || continue
            if have shred; then priv shred -u "$_rt_un_b" 2>/dev/null || priv rm -f "$_rt_un_b"; else priv rm -f "$_rt_un_b"; fi
        done
        priv rm -rf "$RT_TLS_DIR" 2>/dev/null || true
        if [ -n "$RT_SVC_LOG" ]; then
            for _rt_un_log in "$RT_SVC_LOG" "$RT_SVC_LOG".[0-9]*; do
                [ -e "$_rt_un_log" ] || continue
                priv rm -f "$_rt_un_log" 2>/dev/null || true
            done
        fi
        priv rm -rf "$RT_LOG_DIR" 2>/dev/null || true
        priv rmdir "$RT_CONF_DIR" 2>/dev/null || true
        if [ "$RT_SCOPE" = system ]; then
            priv rm -rf "$RT_STATE_DIR" 2>/dev/null || true
            if run_user_exists && have userdel; then
                priv userdel "$RT_RUN_USER" >/dev/null 2>&1 || warn "userdel $RT_RUN_USER 失败（不影响卸载）"
            fi
        fi
        ok "已销毁配置与状态（--purge）"
    else
        if [ -f "$RT_CONF" ]; then
            warn "token 仍保留在 $RT_CONF（重装沿用同一把钥匙）"
            hint "彻底销毁：$RT_NAME uninstall --purge"
            hint "仅销毁凭据：sudo shred -u $RT_CONF"
        fi
    fi
    if [ -f "$RT_SUDOERS_AGENT" ]; then
        hint "如曾手工配置提权，请自行删除：sudo rm -f $RT_SUDOERS_AGENT"
    fi
    if [ -f "$RT_SUDOERS_SCRIPT" ]; then
        hint "脚本层免密规则仍在：sudo rm -f $RT_SUDOERS_SCRIPT"
    fi
    ok "卸载完成"
    log_line "action=uninstall result=ok purge=$RT_PURGE"
    return 0
}

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------
config_key_allowed() {
    case "$1" in
        listen|id|tls_cert|tls_key|allow_sudo|ws_path) return 0 ;;
        token) return 2 ;;
        *) return 1 ;;
    esac
}

cmd_config() {
    _rt_cf_sub=${RT_SUB:-show}
    state_require
    case "$_rt_cf_sub" in
        show)
            [ -f "$RT_CONF" ] || die "$EX_CONFLICT" "配置文件不存在：$RT_CONF"
            hr
            for _rt_cf_k in listen id token tls_cert tls_key allow_sudo ws_path; do
                _rt_cf_v=$(conf_read_key "$_rt_cf_k")
                if [ "$_rt_cf_k" = token ]; then
                    if [ -n "$_rt_cf_v" ]; then
                        say "token       = $(mask_token "$_rt_cf_v")  (fingerprint=$(fingerprint_of "$_rt_cf_v"))"
                    else
                        say "token       = <空>"
                    fi
                else
                    say "$_rt_cf_k = $_rt_cf_v"
                fi
            done
            say "配置文件   = $RT_CONF"
            hr
            hint "改配置：$RT_NAME config set <key> <value> [--restart]；完整 token 只有一条路径：$RT_NAME token show --reveal"
            ;;
        get)
            _rt_cf_key=${RT_REST%% *}
            [ -n "$_rt_cf_key" ] || die "$EX_USAGE" "用法：$RT_NAME config get <key>"
            _rt_cf_rc=0
            config_key_allowed "$_rt_cf_key" || _rt_cf_rc=$?
            case "$_rt_cf_rc" in
                0) : ;;
                2) die "$EX_NOSECRET" "config get token 被拒绝：完整 token 只有一条取值路径 —— $RT_NAME token show --reveal" ;;
                *) die "$EX_USAGE" "未知配置键：$_rt_cf_key（支持 listen/id/tls_cert/tls_key/allow_sudo/ws_path）" ;;
            esac
            conf_read_key "$_rt_cf_key"
            printf '\n'
            ;;
        set)
            _rt_cf_key=${RT_REST%% *}
            _rt_cf_rest=${RT_REST#* }
            if [ "$_rt_cf_rest" = "$RT_REST" ]; then _rt_cf_rest=''; fi
            [ -n "$_rt_cf_key" ] || die "$EX_USAGE" "用法：$RT_NAME config set <key> <value>"
            _rt_cf_rc2=0
            config_key_allowed "$_rt_cf_key" || _rt_cf_rc2=$?
            case "$_rt_cf_rc2" in
                0) : ;;
                2) die "$EX_NOSECRET" "config set token 不存在：写 token 的唯一入口是 $RT_NAME token reset" ;;
                *) die "$EX_USAGE" "未知配置键：$_rt_cf_key" ;;
            esac
            [ -n "$_rt_cf_rest" ] || die "$EX_USAGE" "缺少 value"
            case "$_rt_cf_key" in
                listen)
                case "$_rt_cf_rest" in
                    *:[0-9]*) : ;;
                    *) die "$EX_USAGE" "listen 格式错误（例：:8443 或 127.0.0.1:8443）：$_rt_cf_rest" ;;
                esac
                ;;
                allow_sudo)
                case "$_rt_cf_rest" in
                    true|false|1|0) : ;;
                    *) die "$EX_USAGE" "allow_sudo 只能是 true/false" ;;
                esac
                ;;
                ws_path)
                case "$_rt_cf_rest" in
                    /*) : ;;
                    *) die "$EX_USAGE" "ws_path 必须以 / 开头" ;;
                esac
                ;;
                tls_cert|tls_key)
                [ -f "$_rt_cf_rest" ] || die "$EX_USAGE" "$_rt_cf_key 指向的文件不存在：$_rt_cf_rest"
                ;;
            esac
            if [ "$(conf_read_key "$_rt_cf_key")" = "$_rt_cf_rest" ]; then
                say "值未变化（幂等）：$_rt_cf_key"
                return 0
            fi
            [ "$RT_SCOPE" = system ] && require_root_or_die
            conf_set_key "$_rt_cf_key" "$_rt_cf_rest"
            ok "已写入 $_rt_cf_key = $_rt_cf_rest"
            case "$_rt_cf_key" in
                allow_sudo)
                RT_ALLOW_SUDO_STATE=0
                case "$_rt_cf_rest" in true|1) RT_ALLOW_SUDO_STATE=1 ;; esac
                render_unit "$(conf_read_key listen)" "$(conf_read_key ws_path)" "$RT_ALLOW_SUDO_STATE"
                svc_daemon_reload
                ;;
                listen)
                warn "改端口后防火墙规则需重新放行：sudo ufw allow <新端口>/tcp（或 firewall-cmd --permanent --add-port=<新端口>/tcp）"
                RT_PORT_STATE=$(port_from_listen "$_rt_cf_rest")
                RT_LISTEN_STATE=$_rt_cf_rest
                ;;
                ws_path)
                RT_WS_PATH_STATE=$_rt_cf_rest
                render_unit "$(conf_read_key listen)" "$RT_WS_PATH_STATE" "${RT_ALLOW_SUDO_STATE:-0}"
                svc_daemon_reload
                ;;
                tls_cert|tls_key)
                RT_TLS_ENABLED=true
                RT_TLS_CERT_STATE=$(conf_read_key tls_cert)
                ;;
            esac
            if [ "$RT_RESTART" = 1 ]; then
                svc_restart || die "$EX_SERVICE" "重启失败，排错：$RT_NAME logs"
                ok "已重启生效"
            else
                hint "配置已写入，但 agent 只在启动时读取：加 --restart 或手动 $RT_NAME restart 生效"
            fi
            log_line "action=config.set key=$_rt_cf_key result=ok"
            ;;
        edit)
            [ -f "$RT_CONF" ] || die "$EX_CONFLICT" "配置文件不存在：$RT_CONF"
            [ "$RT_SCOPE" = system ] && require_root_or_die
            rt_tmpfile
            _rt_cf_tmp=$RT_TMPFILE
            priv cat "$RT_CONF" >"$_rt_cf_tmp" || die "$EX_FAIL" "读取配置失败"
            _rt_cf_ed=${RT_EDITOR_CMD:-vi}
            if ! have "$_rt_cf_ed"; then
                rm -f "$_rt_cf_tmp" 2>/dev/null || true
                die "$EX_FAIL" "编辑器不可用：$_rt_cf_ed（用 --editor nano 指定）"
            fi
            if [ "$RT_TTY" = 1 ]; then
                "$_rt_cf_ed" "$_rt_cf_tmp" </dev/tty >/dev/tty 2>&1 || true
            else
                rm -f "$_rt_cf_tmp" 2>/dev/null || true
                die "$EX_USAGE" "config edit 需要交互终端（可改用 $RT_NAME config set <key> <value>）"
            fi
            _rt_cf_ok=1
            for _rt_cf_k2 in listen id token; do
                if [ -z "$(sed -n "s/^[[:space:]]*${_rt_cf_k2}[[:space:]]*=[[:space:]]*//p" "$_rt_cf_tmp" 2>/dev/null | head -n1 || true)" ]; then
                    err "缺少必填键：$_rt_cf_k2"
                    _rt_cf_ok=0
                fi
            done
            if [ "$_rt_cf_ok" != 1 ]; then
                rm -f "$_rt_cf_tmp" 2>/dev/null || true
                die "$EX_USAGE" "编辑结果校验失败，已放弃写入（原文件未改动）"
            fi
            atomic_put "$_rt_cf_tmp" "$RT_CONF" 0600 "$RT_RUN_USER:$RT_RUN_GROUP" || {
                rm -f "$_rt_cf_tmp" 2>/dev/null || true
                die "$EX_FAIL" "写入配置失败"
            }
            rm -f "$_rt_cf_tmp" 2>/dev/null || true
            conf_finish_perms "$RT_CONF"
            ok "配置已更新（0600 $RT_RUN_USER:$RT_RUN_GROUP）"
            if [ "$RT_RESTART" = 1 ]; then svc_restart || warn "重启失败"; else hint "记得 $RT_NAME restart 使配置生效"; fi
            ;;
        *)
            die "$EX_USAGE" "用法：$RT_NAME config show|get <key>|set <key> <value>|edit"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# token
# ---------------------------------------------------------------------------
probe_token_ok() {
    _rt_pt_tok=$1
    [ -x "$RT_BIN_CLIENT" ] || return 2
    if [ "${RT_TLS_ENABLED:-false}" = true ]; then return 3; fi
    _rt_pt_url="ws://$(probe_host "$RT_LISTEN_STATE"):$RT_PORT_STATE${RT_WS_PATH_STATE:-/ws}"
    "$RT_BIN_CLIENT" -server "$_rt_pt_url" exec -token "$_rt_pt_tok" -c true >/dev/null 2>&1
}

cmd_token() {
    _rt_tk_sub=${RT_SUB:-show}
    state_require
    case "$_rt_tk_sub" in
        show)
            _rt_tk=$(token_value || true)
            if [ -z "$_rt_tk" ]; then
                die "$EX_CONFLICT" "无法读取 token（配置缺失或无权限）：sudo $RT_NAME token show --reveal"
            fi
            if [ "$RT_REVEAL" = 1 ]; then
                if [ ! -t 1 ] && [ "$RT_FORCE" != 1 ]; then
                    die "$EX_NOSECRET" "拒绝在非终端输出完整 token（如确需请加 --force，并确认输出不会进日志/CI）"
                fi
                if [ "$RT_FORCE" = 1 ]; then
                    warn "--force：完整 token 已输出，请勿重定向到文件或日志"
                fi
                say "token = $_rt_tk"
                say "fingerprint = $(fingerprint_of "$_rt_tk")"
                warn "token 即设备全部权限，勿贴群聊、工单、截图、CI 日志"
            else
                say "token = $(mask_token "$_rt_tk")"
                say "fingerprint = $(fingerprint_of "$_rt_tk")"
                say "length = ${#_rt_tk}"
                say "来源 = $RT_CONF"
                hint "完整值：sudo $RT_NAME token show --reveal   （需交互终端）"
            fi
            ;;
        reset)
            [ "$RT_SCOPE" = system ] && require_root_or_die
            [ -f "$RT_CONF" ] || die "$EX_CONFLICT" "配置文件不存在：$RT_CONF"
            if [ "$RT_YES" != 1 ]; then
                warn "轮换会重启 agent 并断开全部现有会话；旧 token 在重启完成前一直有效"
                if ! ask_yn '确认轮换 token？' 'n'; then say '已取消'; return 0; fi
            fi
            _rt_tr_bak="$RT_CONF.bak-$(date +%Y%m%dT%H%M%S 2>/dev/null || printf '%s' "$$")"
            priv cp -p "$RT_CONF" "$_rt_tr_bak" || die "$EX_FAIL" "备份配置失败"
            priv chmod 0600 "$_rt_tr_bak" || true
            if [ "$RT_SCOPE" = system ]; then priv chown "$RT_RUN_USER:$RT_RUN_GROUP" "$_rt_tr_bak" || true; fi
            _rt_tr_old=$(token_value || true)
            _rt_tr_new=''
            if have openssl; then
                _rt_tr_new=$(openssl rand -hex 32 2>/dev/null || true)
            fi
            if [ -z "$_rt_tr_new" ] && [ -r /dev/urandom ] && have od; then
                _rt_tr_new=$(od -An -tx1 -N32 </dev/urandom 2>/dev/null | tr -d ' \n' || true)
            fi
            if [ -z "$_rt_tr_new" ]; then
                die "$EX_FAIL" "无法生成新 token（缺 openssl 与 /dev/urandom）"
            fi
            conf_set_key token "$_rt_tr_new"
            if ! svc_restart; then
                warn "重启失败，回滚配置"
                priv cp -p "$_rt_tr_bak" "$RT_CONF" || true
                conf_finish_perms "$RT_CONF"
                svc_restart >/dev/null 2>&1 || true
                die "$EX_SERVICE" "token 轮换失败，已回滚（旧 token 仍有效）"
            fi
            _rt_tr_newtok=$(token_value || true)
            if probe_token_ok "$_rt_tr_newtok"; then
                ok "新 token 探针通过"
            else
                _rt_tr_prc=$?
                case "$_rt_tr_prc" in
                    2) warn "缺少本机客户端 $RT_BIN_CLIENT，跳过双探针" ;;
                    3) warn "已启用 TLS 且客户端走系统信任库，跳过本机双探针（请在控制机手工验证）" ;;
                    *) warn "新 token 探针失败（可能健康检查未就绪），请手工验证" ;;
                esac
            fi
            if [ -n "$_rt_tr_old" ] && probe_token_ok "$_rt_tr_old"; then
                warn "旧 token 仍然可用：请确认 agent 已真正重启"
            fi
            say "新 token = $(mask_token "$_rt_tr_newtok")  fingerprint=$(fingerprint_of "$_rt_tr_newtok")"
            hint "完整值：sudo $RT_NAME token show --reveal"
            hint "备份（含旧 token，0600）：$_rt_tr_bak；销毁：sudo shred -u $_rt_tr_bak"
            log_line 'action=token.reset result=ok'
            ;;
        *)
            die "$EX_USAGE" "用法：$RT_NAME token show [--reveal] [--force] | $RT_NAME token reset [--yes]"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# sudo：agent 层授权（永久 sudoers / 临时密码）
# ---------------------------------------------------------------------------
write_sudoers() {
    _rt_ws_path_target=$1
    _rt_ws_content=$2
    if ! have visudo; then
        die "$EX_FAIL" "缺少 visudo：拒绝在无法校验语法的情况下写 sudoers（语法错误会让全系统 sudo 失效）"
    fi
    rt_tmpfile
    _rt_ws_tmp=$RT_TMPFILE
    printf '%s\n' "$_rt_ws_content" >"$_rt_ws_tmp"
    priv chown root:root "$_rt_ws_tmp" || true
    priv chmod 0440 "$_rt_ws_tmp" || true
    if ! priv visudo -cf "$_rt_ws_tmp" >/dev/null 2>&1; then
        rm -f "$_rt_ws_tmp" 2>/dev/null || true
        die "$EX_FAIL" "sudoers 语法校验失败（visudo -cf），已放弃写入"
    fi
    if ! atomic_put "$_rt_ws_tmp" "$_rt_ws_path_target" 0440 root:root; then
        rm -f "$_rt_ws_tmp" 2>/dev/null || true
        die "$EX_FAIL" "写入 sudoers 失败：$_rt_ws_path_target"
    fi
    rm -f "$_rt_ws_tmp" 2>/dev/null || true
    ok "已写入 $_rt_ws_path_target（0440 root:root，visudo 校验通过）"
}

cmd_sudo() {
    _rt_sd_sub=${RT_SUB:-status}
    state_require
    [ "$RT_SCOPE" = system ] && require_root_or_die
    case "$_rt_sd_sub" in
        enable)
            if [ -f "$RT_SUDOERS_AGENT" ] && [ "${RT_TEMP:-0}" != 1 ]; then
                info "$RT_SUDOERS_AGENT 已存在（幂等）"
            fi
            if [ "${RT_TEMP:-0}" = 1 ]; then
                conf_set_key allow_sudo true
                RT_ALLOW_SUDO_STATE=1
                render_unit "$(conf_read_key listen)" "$(conf_read_key ws_path)" 1
                svc_daemon_reload
                svc_restart >/dev/null 2>&1 || warn "重启失败，请手动 $RT_NAME restart"
                ok "已开启临时授权（allow_sudo=true，不写 sudoers）"
                hint "控制端用法：rtctl -server ... exec -token <token> -sudo -c 'systemctl restart nginx'"
                hint "客户端会当场询问 root 密码，agent 用 sudo -S 从 stdin 读取（协议字段 sudo_password），密码不落盘"
                return 0
            fi
            warn "永久授权：执行后任何持有本机 token 的人都能获得 root"
            if [ "$RT_YES" != 1 ]; then
                if ! ask_yn '确认写入 NOPASSWD sudoers？' 'n'; then say '已取消'; return 0; fi
            fi
            write_sudoers "$RT_SUDOERS_AGENT" \
                "$RT_RUN_USER ALL=(ALL) NOPASSWD: /bin/sh, /usr/bin/sh, /usr/bin/kill, /bin/kill"
            conf_set_key allow_sudo true
            RT_ALLOW_SUDO_STATE=1
            render_unit "$(conf_read_key listen)" "$(conf_read_key ws_path)" 1
            svc_daemon_reload
            svc_restart >/dev/null 2>&1 || warn "重启失败，请手动 $RT_NAME restart"
            ok "已开启永久授权（sudoers + allow_sudo=true，NoNewPrivileges=no）"
            log_line 'action=sudo.enable result=ok mode=permanent'
            ;;
        temp)
            RT_TEMP=1
            RT_SUB=enable
            cmd_sudo
            ;;
        disable)
            if [ -f "$RT_SUDOERS_AGENT" ]; then
                priv rm -f "$RT_SUDOERS_AGENT" || warn "删除 $RT_SUDOERS_AGENT 失败"
                ok "已删除 $RT_SUDOERS_AGENT"
            else
                info "$RT_SUDOERS_AGENT 不存在（幂等）"
            fi
            conf_set_key allow_sudo false
            RT_ALLOW_SUDO_STATE=0
            render_unit "$(conf_read_key listen)" "$(conf_read_key ws_path)" 0
            svc_daemon_reload
            svc_restart >/dev/null 2>&1 || warn "重启失败，请手动 $RT_NAME restart"
            ok "已关闭提权（allow_sudo=false，NoNewPrivileges=yes）"
            log_line 'action=sudo.disable result=ok'
            ;;
        status)
            _rt_sd_as=$(conf_read_key allow_sudo)
            hr
            say "agent 层 allow_sudo = ${_rt_sd_as:-<空>}"
            if [ -f "$RT_SUDOERS_AGENT" ]; then
                say "永久授权 sudoers = 存在（$RT_SUDOERS_AGENT，$(priv stat -c '%a %U:%G' "$RT_SUDOERS_AGENT" 2>/dev/null || printf '?')）"
                warn "该规则等价于：token 持有者 = root"
            else
                say "永久授权 sudoers = 不存在"
            fi
            if [ "$RT_INIT" = systemd ] && [ -f "$RT_UNIT" ]; then
                say "unit NoNewPrivileges = $(sed -n 's/^NoNewPrivileges=//p' "$RT_UNIT" 2>/dev/null | head -n1 || printf '?')"
            fi
            say "脚本层免密（$RT_SUDOERS_SCRIPT） = $(if [ -f "$RT_SUDOERS_SCRIPT" ]; then printf '存在'; else printf '不存在'; fi)"
            case "$_rt_sd_as" in
                true|TRUE|True|1)
                    if [ -f "$RT_SUDOERS_AGENT" ]; then
                        hint "当前是永久授权：远程 -sudo 不需要密码"
                    else
                        hint "当前是临时授权：远程 -sudo 会提示输入 root 密码（agent 用 sudo -S 读取）"
                    fi
                    ;;
                *)
                    hint "当前关闭提权：远程 -sudo 返回 sudo_disabled；开启：$RT_NAME sudo enable（永久） 或 $RT_NAME sudo temp（临时）"
                    ;;
            esac
            hr
            ;;
        *)
            die "$EX_USAGE" "用法：$RT_NAME sudo enable|temp|disable|status"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# proxy：反向代理 / 路径前缀模板
# ---------------------------------------------------------------------------
cmd_proxy() {
    _rt_px_kind=${RT_SUB:-nginx}
    _rt_px_port=${RT_PORT_STATE:-}
    if [ -z "$_rt_px_port" ]; then
        if load_state; then _rt_px_port=$RT_PORT_STATE; fi
    fi
    if [ -z "$_rt_px_port" ]; then
        die "$EX_CONFLICT" "未知监听端口：请先安装，或用 $RT_NAME install 完成安装"
    fi
    _rt_px_domain=${RT_PROXY_DOMAIN:-<你的域名>}
    _rt_px_ws=${RT_WS_PATH_STATE:-/ws}
    case "$_rt_px_ws" in
        /ws) _rt_px_prefix='' ;;
        *) _rt_px_prefix=$(printf '%s' "$_rt_px_ws" | sed -e 's|/ws$||') ;;
    esac
    [ -n "$_rt_px_prefix" ] || _rt_px_prefix='/rt'
    case "$_rt_px_kind" in
        nginx)
            printf '%s\n' \
                "# /etc/nginx/conf.d/rtctl.conf —— 由 $RT_NAME proxy nginx 生成（域名：$_rt_px_domain）" \
                "# 路径前缀：外部 /rt/ -> agent；proxy_pass 末尾的 / 会剥掉 /rt/ 前缀" \
                "map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }" \
                "" \
                "server {" \
                "    listen 443 ssl;" \
                "    server_name $_rt_px_domain;" \
                "" \
                "    ssl_certificate     /etc/letsencrypt/live/$_rt_px_domain/fullchain.pem;" \
                "    ssl_certificate_key /etc/letsencrypt/live/$_rt_px_domain/privkey.pem;" \
                "" \
                "    # 反向代理 + WebSocket 升级头（缺一不可，否则 shell/交互会 400）" \
                "    location $_rt_px_prefix/ {" \
                "        proxy_pass http://127.0.0.1:$_rt_px_port/;" \
                "        proxy_http_version 1.1;" \
                "        proxy_set_header Upgrade \$http_upgrade;" \
                "        proxy_set_header Connection \$connection_upgrade;" \
                "        proxy_set_header Host \$host;" \
                "        proxy_set_header X-Real-IP \$remote_addr;" \
                "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
                "        proxy_read_timeout 3600s;" \
                "        proxy_send_timeout 3600s;" \
                "        proxy_buffering off;" \
                "    }" \
                "" \
                "    # 健康检查直通（agent 同时注册在 /healthz 与 前缀+/healthz）" \
                "    location = $_rt_px_prefix/healthz {" \
                "        proxy_pass http://127.0.0.1:$_rt_px_port/healthz;" \
                "    }" \
                "}"
            say ''
            hint "启用：sudo cp 上述内容到 /etc/nginx/conf.d/rtctl.conf && sudo nginx -t && sudo systemctl reload nginx"
            hint "路径前缀要让 agent 也认这个前缀：$RT_NAME config set ws_path $_rt_px_prefix$_rt_px_ws --restart"
            hint "控制端：rtctl -server wss://$_rt_px_domain$_rt_px_prefix$_rt_px_ws exec -token <token> -c 'uptime'"
            ;;
        caddy)
            printf '%s\n' \
                "# /etc/caddy/Caddyfile —— 由 $RT_NAME proxy caddy 生成（域名：$_rt_px_domain）" \
                "# Caddy 自动处理 WebSocket 升级与证书申请" \
                "$_rt_px_domain {" \
                "    handle_path $_rt_px_prefix/* {" \
                "        reverse_proxy 127.0.0.1:$_rt_px_port" \
                "    }" \
                "}" \
                "" \
                "# 若要让 agent 也认这个前缀（推荐，配合 handle_path 剥前缀时可省）：" \
                "#   $RT_NAME config set ws_path $_rt_px_prefix$_rt_px_ws --restart"
            say ''
            hint "启用：sudo cp 上述内容到 /etc/caddy/Caddyfile && sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy"
            hint "控制端：rtctl -server wss://$_rt_px_domain$_rt_px_prefix$_rt_px_ws exec -token <token> -c 'uptime'"
            ;;
        *)
            die "$EX_USAGE" "用法：$RT_NAME proxy nginx|caddy [--proxy-domain 域名]"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# doctor：只读自检（ok/warn/fail，有 fail -> exit 10）
# ---------------------------------------------------------------------------
doctor_fail=0
doctor_ok() { printf '  %sok%s   %s\n' "$C_OK" "$C_RST" "$*"; }
doctor_warn() { printf '  %swarn%s %s\n' "$C_WARN" "$C_RST" "$*"; }
doctor_bad() { printf '  %sfail%s %s\n' "$C_ERR" "$C_RST" "$*"; doctor_fail=$((doctor_fail + 1)); }

cmd_doctor() {
    doctor_fail=0
    say "rtctl doctor —— 只读自检（脚本 $RT_VERSION）"
    if ! load_state; then
        doctor_bad "未检测到安装状态：$RT_STATE_FILE（先 $RT_NAME install）"
    fi
    case "$(uname -s 2>/dev/null || printf '')" in
        Linux) doctor_ok "平台 Linux/$(uname -m)" ;;
        *) doctor_bad "平台不是 Linux：$(uname -s)" ;;
    esac
    if [ -n "${RT_BIN_AGENT:-}" ] && [ -x "$RT_BIN_AGENT" ]; then
        doctor_ok "agent 二进制：$RT_BIN_AGENT（$RT_AGENT_VERSION）"
        _rt_dc_sha=$(sha256_of "$RT_BIN_AGENT" || true)
        if [ -n "$_rt_dc_sha" ] && [ -n "${RT_AGENT_SHA256:-}" ] && [ "$_rt_dc_sha" != "$RT_AGENT_SHA256" ]; then
            doctor_warn "agent 二进制 sha256 与安装记录不一致（本地篡改基线，非信任锚）"
        fi
    else
        doctor_bad "agent 二进制缺失或不可执行：${RT_BIN_AGENT:-<未知>}"
    fi
    if [ -f "${RT_CONF:-/nonexistent}" ]; then
        _rt_dc_perm=$(priv stat -c '%a %U:%G' "$RT_CONF" 2>/dev/null || printf '?')
        case "$_rt_dc_perm" in
            '600 rtctl:rtctl') doctor_ok "配置权限：$_rt_dc_perm" ;;
            *) doctor_warn "配置权限异常：$_rt_dc_perm（期望 600 rtctl:rtctl）" ;;
        esac
        _rt_dc_tok=$(token_value || true)
        if [ -n "$_rt_dc_tok" ]; then doctor_ok "token 可读（fingerprint=$(fingerprint_of "$_rt_dc_tok")）"; else doctor_warn "token 读不到（无权限？）"; fi
    else
        doctor_bad "配置文件缺失：${RT_CONF:-<未知>}"
    fi
    if [ -d "${RT_CONF_DIR:-/nonexistent}" ]; then
        _rt_dc_dperm=$(priv stat -c '%a %U:%G' "$RT_CONF_DIR" 2>/dev/null || printf '?')
        case "$_rt_dc_dperm" in
            '750 root:rtctl'|'710 root:rtctl') doctor_ok "配置目录权限：$_rt_dc_dperm" ;;
            *) doctor_warn "配置目录权限异常：$_rt_dc_dperm（期望 750 root:rtctl）" ;;
        esac
    fi
    if svc_active; then doctor_ok "服务 active（$RT_INIT）"; else doctor_bad "服务未运行（$RT_NAME start，排错 $RT_NAME logs）"; fi
    if svc_enabled; then doctor_ok "开机自启 enabled"; else doctor_warn "开机自启未启用（$RT_NAME enable）"; fi
    _rt_dc_port=${RT_PORT_STATE:-$(port_from_listen "${RT_LISTEN_STATE:-}")}
    if [ -n "$_rt_dc_port" ]; then
        if port_in_use "$_rt_dc_port"; then doctor_ok "端口 $_rt_dc_port 正在监听"; else doctor_bad "端口 $_rt_dc_port 未监听"; fi
        _rt_dc_cfport=$(port_from_listen "$(conf_read_key listen)")
        if [ -n "$_rt_dc_cfport" ] && [ "$_rt_dc_cfport" != "$_rt_dc_port" ]; then
            doctor_warn "配置 listen 端口（$_rt_dc_cfport）与状态文件（$_rt_dc_port）不一致"
        fi
    else
        doctor_bad "无法确定监听端口"
    fi
    if [ "${RT_TLS_ENABLED:-false}" = true ]; then
        doctor_ok "TLS 已启用"
        if tls_verify_pair "$(conf_read_key tls_cert)" "$(conf_read_key tls_key)"; then
            doctor_ok "证书与私钥匹配"
        else
            doctor_bad "证书与私钥不匹配（openssl modulus 不一致）"
        fi
    else
        doctor_bad "未启用 TLS：token 与命令明文传输，同网段可被截获（补救：$RT_NAME install --tls-generate）"
    fi
    if [ "${RT_CAP_PRINT_TOKEN:-false}" = true ]; then
        if [ -f "${RT_UNIT:-}" ] && grep -q -- '-print-token=false' "$RT_UNIT" 2>/dev/null; then
            doctor_ok "unit 已传 -print-token=false（token 不进 journald）"
        else
            doctor_warn "二进制支持 -print-token 但 unit 未传：重跑 $RT_NAME install 或 $RT_NAME config set ws_path 同值刷新单元"
        fi
    else
        if [ -f "${RT_UNIT:-}" ] && grep -q -- '-print-token=false' "$RT_UNIT" 2>/dev/null; then
            doctor_bad "unit 传了 -print-token=false 但二进制不支持（会崩溃循环）"
        else
            doctor_warn "agent 不支持 -print-token：启动块会把完整 token 打进 journald，建议升级"
        fi
    fi
    _rt_dc_as=$(conf_read_key allow_sudo)
    case "$_rt_dc_as" in
        true|TRUE|True|1)
            doctor_warn "allow_sudo=true：任何持有 token 的人都能提权到 root"
            if [ -f "$RT_SUDOERS_AGENT" ]; then doctor_warn "$RT_SUDOERS_AGENT 存在（永久授权，等价 root 通道）"; else doctor_ok "未写 sudoers（临时授权形态）"; fi
            if [ -f "${RT_UNIT:-}" ]; then
                if grep -q '^NoNewPrivileges=yes' "$RT_UNIT" 2>/dev/null; then
                    doctor_bad "allow_sudo=true 但 unit 里 NoNewPrivileges=yes：sudo 会被拦（重跑 $RT_NAME sudo enable）"
                fi
            fi
            ;;
        *)
            if [ -f "$RT_SUDOERS_AGENT" ]; then
                doctor_warn "$RT_SUDOERS_AGENT 存在但 allow_sudo=false：残留 root 通道，建议 $RT_NAME sudo disable"
            else
                doctor_ok "提权关闭（allow_sudo=false）"
            fi
            ;;
    esac
    if assert_no_secret "$RT_STATE_FILE"; then
        doctor_ok "状态文件无秘密（assert_no_secret）"
    else
        doctor_bad "状态文件命中疑似凭据"
    fi
    if [ -f "${RT_LOG_FILE:-}" ]; then
        if assert_no_secret "$RT_LOG_FILE"; then doctor_ok "脚本日志无秘密"; else doctor_warn "脚本日志命中疑似凭据（请检查）"; fi
    fi
    if [ "$RT_SCOPE" = system ]; then
        if [ -d "${RT_STATE_DIR:-}" ]; then doctor_ok "HOME 目录存在：$RT_STATE_DIR"; else doctor_warn "HOME 目录缺失（远程子命令写 \$HOME 会失败）：$RT_STATE_DIR"; fi
        if run_user_exists; then doctor_ok "运行用户 $RT_RUN_USER 存在"; else doctor_bad "运行用户 $RT_RUN_USER 不存在"; fi
        if have pgrep; then
            _rt_dc_dup=$(pgrep -f "^${RT_BIN_AGENT:-/nonexistent}" 2>/dev/null | wc -l || printf '0')
            if [ "${_rt_dc_dup:-0}" -gt 1 ] 2>/dev/null; then
                doctor_warn "检测到多个 agent 进程（$_rt_dc_dup 个），可能手工 nohup 与服务抢端口"
            fi
        fi
    fi
    if [ "$RT_INIT" = nohup ] && [ ! -f /etc/cron.d/rtctl-agent ]; then
        doctor_warn "无 init 且无 @reboot：重启后不会自动拉起"
    fi
    say ''
    if [ "$doctor_fail" -gt 0 ]; then
        err "doctor：$doctor_fail 项未通过"
        return "$EX_DOCTOR"
    fi
    ok "doctor：全部通过"
    return 0
}

# ---------------------------------------------------------------------------
# connect / version / help / 占位命令
# ---------------------------------------------------------------------------
cmd_connect() {
    state_require
    print_guidance
}

cmd_version() {
    _rt_v_have=0
    if load_state; then _rt_v_have=1; fi
    if [ "$RT_JSON" = 1 ]; then
        printf '{"script":"%s","scope":"%s","init":"%s","agent":"%s","client":"%s","listen":"%s","port":"%s","ws_path":"%s","tls":%s,"state":"%s"}\n' \
            "$RT_VERSION" "${RT_SCOPE:-unknown}" "${RT_INIT:-unknown}" "${RT_AGENT_VERSION:-unknown}" \
            "$(if [ -x "${RT_BIN_CLIENT:-}" ]; then "${RT_BIN_CLIENT}" -version 2>/dev/null | awk '{print $NF}' || printf 'unknown'; else printf 'unknown'; fi)" \
            "${RT_LISTEN_STATE:-unknown}" "${RT_PORT_STATE:-unknown}" "${RT_WS_PATH_STATE:-/ws}" \
            "$(if [ "${RT_TLS_ENABLED:-false}" = true ]; then printf 'true'; else printf 'false'; fi)" \
            "$RT_STATE_FILE"
        return 0
    fi
    say "rtctl 管理脚本 : $RT_VERSION"
    say "scope          : ${RT_SCOPE:-unknown}"
    say "服务后端       : ${RT_INIT:-unknown}"
    say "agent 版本     : ${RT_AGENT_VERSION:-unknown}"
    say "客户端版本     : $(if [ -x "${RT_BIN_CLIENT:-/nonexistent}" ]; then "${RT_BIN_CLIENT}" -version 2>/dev/null | awk '{print $NF}' || printf 'unknown'; else printf '未安装'; fi)"
    if [ "$_rt_v_have" = 1 ]; then
        say "监听           : ${RT_LISTEN_STATE:-unknown}"
        say "状态文件       : $RT_STATE_FILE"
    else
        say "安装状态       : 未安装（$RT_STATE_FILE 不存在）"
    fi
    return 0
}

cmd_help() {
    say "rtctl $RT_VERSION —— Linux 安装与管理脚本（安装后命令名 rt）"
    say ''
    say "用法: $RT_NAME <命令> [子命令] [选项]"
    say ''
    printf '%-10s %-8s %-6s %s\n' '命令' '风险' '需root' '说明'
    hr
    rt_cmd_table | while IFS="$RT_TAB" read -r _rt_h_name _rt_h_handler _rt_h_risk _rt_h_root _rt_h_desc; do
        [ -n "$_rt_h_name" ] || continue
        printf '%-10s %-8s %-6s %s\n' "$_rt_h_name" "$_rt_h_risk" "$_rt_h_root" "$_rt_h_desc"
    done
    hr
    say '全局选项: --scope system|user  --prefix DIR  --yes  --json  --quiet  --verbose'
    say '安装选项: --port N  --listen ADDR  --id NAME  --ws-path /rt/ws  --tls-generate'
    say '          --tls-cert FILE --tls-key FILE  --allow-sudo  --sudo ask|nopasswd'
    say '          --proxy-domain DOMAIN  --base-url URL  --release vX.Y.Z  --agent-src FILE'
    say '          --pinned-sha256 HEX  --no-firewall  --allow-from CIDR  --proxy URL  --init systemd|openrc|nohup'
    say ''
    say '退出码: 0 成功 | 1 通用失败 | 2 用法错误 | 3 平台/架构不支持 | 4 下载失败 | 5 校验失败'
    say '        6 权限不足 | 7 服务操作失败 | 8 配置冲突 | 9 健康检查失败(已回滚) | 10 doctor 未通过'
    say '        11 功能未实现 | 12 拒绝在非终端输出敏感内容 | 75 锁被占用'
    say ''
    say "示例: $RT_NAME install --tls-generate        # 安装（自签 TLS + 随机端口）"
    say "      $RT_NAME token show --reveal           # 查看完整 token（需交互终端）"
    say "      $RT_NAME proxy nginx                   # 生成反向代理模板"
    say "      $RT_NAME doctor                        # 自检"
    return 0
}

cmd_not_implemented() {
    _rt_ni=${RT_CMD:-unknown}
    err "功能 $_rt_ni 尚未实现（计划在后续版本落地）"
    hint "当前可用命令：$RT_NAME help"
    exit "$EX_UNIMPL"
}

# ---------------------------------------------------------------------------
# 注册表：name<TAB>handler<TAB>risk<TAB>needs_root<TAB>desc
# ---------------------------------------------------------------------------
rt_cmd_table() {
    cat <<'RTCTL_CMD_TABLE'
install	cmd_install	high	yes	下载校验落盘、建用户/目录、配置、服务、防火墙、启动
init	cmd_init	mid	yes	生成 agent.conf 与 token（已存在则 exit 8）
start	cmd_start	mid	yes	启动服务
stop	cmd_stop	mid	yes	停止服务（不做 kill -9）
restart	cmd_restart	mid	yes	重启服务并做健康检查
status	cmd_status	low	no	只读状态汇总
logs	cmd_logs	low	no	查看日志（--follow 跟随，默认过滤 token）
enable	cmd_enable	mid	yes	开机自启
disable	cmd_disable	mid	yes	关闭开机自启
upgrade	cmd_upgrade	high	yes	停服务 -> 原子替换 -> 健康检查 -> 失败回滚
uninstall	cmd_uninstall	high	yes	卸载（默认保留配置，--purge 才销毁）
config	cmd_config	mid	yes	配置 show/get/set/edit（token 键一律拒绝）
token	cmd_token	mid	yes	token show（默认 masked）/ reset（双探针）
sudo	cmd_sudo	high	yes	提权授权 enable/temp/disable/status
proxy	cmd_proxy	low	no	反向代理与路径前缀模板 nginx/caddy
doctor	cmd_doctor	low	no	只读自检（有 fail -> exit 10）
connect	cmd_connect	low	no	重放安装引导与连接示例
version	cmd_version	low	no	版本与状态
help	cmd_help	low	no	命令列表与退出码
harden	cmd_not_implemented	mid	no	可选 systemd 加固 drop-in（未实现）
backup	cmd_not_implemented	mid	no	备份配置与状态（未实现）
restore	cmd_not_implemented	mid	no	从备份恢复（未实现）
migrate	cmd_not_implemented	mid	no	迁移到新端口/新机器（未实现）
RTCTL_CMD_TABLE
}

rt_dispatch() {
    _rt_dp_cmd=$1
    shift || true
    _rt_dp_handler=''
    while IFS="$RT_TAB" read -r _rt_dp_name _rt_dp_h _rt_dp_risk _rt_dp_root _rt_dp_desc; do
        [ -n "$_rt_dp_name" ] || continue
        if [ "$_rt_dp_name" = "$_rt_dp_cmd" ]; then
            _rt_dp_handler=$_rt_dp_h
            break
        fi
    done <<RTCTL_TABLE
$(rt_cmd_table)
RTCTL_TABLE
    if [ -z "$_rt_dp_handler" ]; then
        err "未知命令：$_rt_dp_cmd"
        hint "运行 $RT_NAME help 查看可用命令"
        exit "$EX_USAGE"
    fi
    RT_CMD=$_rt_dp_cmd
    "$_rt_dp_handler"
    return $?
}

# ---------------------------------------------------------------------------
# 参数解析（不读任何环境变量作为输入）
# ---------------------------------------------------------------------------
parse_args() {
    RT_CMD=''
    RT_SUB=''
    RT_REST=''
    while [ $# -gt 0 ]; do
        _rt_pa_arg=$1
        shift
        _rt_pa_val=''
        case "$_rt_pa_arg" in
            --*=*) _rt_pa_val=${_rt_pa_arg#*=}; _rt_pa_arg=${_rt_pa_arg%%=*} ;;
        esac
        case "$_rt_pa_arg" in
            --scope|--prefix|--port|--listen|--id|--ws-path|--tls-cert|--tls-key|--sudo|--proxy-domain|--base-url|--release|--pinned-sha256|--init|--editor|--proxy|--allow-from|--agent-src)
                if [ -z "$_rt_pa_val" ]; then
                    if [ $# -gt 0 ]; then
                        _rt_pa_val=$1
                        shift
                    else
                        die "$EX_USAGE" "选项 $_rt_pa_arg 需要一个值"
                    fi
                fi
                ;;
        esac
        case "$_rt_pa_arg" in
            --scope)
                case "$_rt_pa_val" in
                    system|user) RT_SCOPE=$_rt_pa_val ;;
                    *) die "$EX_USAGE" "--scope 只能是 system 或 user" ;;
                esac
                ;;
            --prefix) RT_PREFIX=$_rt_pa_val ;;
            --port) RT_PORT=$_rt_pa_val ;;
            --listen) RT_LISTEN=$_rt_pa_val ;;
            --id) RT_ID=$_rt_pa_val ;;
            --ws-path)
                case "$_rt_pa_val" in
                    /*) RT_WS_PATH=$_rt_pa_val ;;
                    *) RT_WS_PATH="/$_rt_pa_val" ;;
                esac
                ;;
            --tls-cert) RT_TLS_CERT=$_rt_pa_val ;;
            --tls-key) RT_TLS_KEY=$_rt_pa_val ;;
            --sudo)
                case "$_rt_pa_val" in
                    ask|nopasswd) RT_SUDO_MODE=$_rt_pa_val ;;
                    *) die "$EX_USAGE" "--sudo 只能是 ask 或 nopasswd" ;;
                esac
                ;;
            --proxy-domain) RT_PROXY_DOMAIN=$_rt_pa_val ;;
            --base-url) RT_BASE_URL=${_rt_pa_val%/} ;;
            --release) RT_RELEASE=$_rt_pa_val ;;
            --pinned-sha256) RT_PINNED=$_rt_pa_val ;;
            --init)
                case "$_rt_pa_val" in
                    systemd|openrc|nohup) RT_INIT_FORCE=$_rt_pa_val ;;
                    *) die "$EX_USAGE" "--init 只能是 systemd|openrc|nohup" ;;
                esac
                ;;
            --editor) RT_EDITOR_CMD=$_rt_pa_val ;;
            --proxy) RT_PROXY=$_rt_pa_val ;;
            --allow-from) RT_ALLOW_FROM=$_rt_pa_val ;;
            --agent-src) RT_AGENT_SRC=$_rt_pa_val ;;
            --tls-generate) RT_TLS_GEN=1 ;;
            --allow-sudo) RT_ALLOW_SUDO=1 ;;
            --no-firewall) RT_NO_FIREWALL=1 ;;
            --yes|-y) RT_YES=1 ;;
            --json) RT_JSON=1 ;;
            --quiet|-q) RT_QUIET=1 ;;
            --verbose|-v) RT_VERBOSE=1 ;;
            --purge) RT_PURGE=1 ;;
            --check) RT_CHECK=1 ;;
            --restart) RT_RESTART=1 ;;
            --reveal) RT_REVEAL=1 ;;
            --force) RT_FORCE=1 ;;
            --temp) RT_TEMP=1 ;;
            --detached) RT_DETACHED=1 ;;
            --follow|-f) RT_FOLLOW=1 ;;
            --no-print-token) RT_NO_PRINT_TOKEN=1 ;;
            -h|--help) RT_CMD='help' ;;
            -V|--version) RT_CMD='version' ;;
            --) : ;;
            -*) die "$EX_USAGE" "未知选项：$_rt_pa_arg" ;;
            *)
                if [ -z "$RT_CMD" ]; then
                    RT_CMD=$_rt_pa_arg
                elif [ -z "$RT_SUB" ]; then
                    RT_SUB=$_rt_pa_arg
                else
                    if [ -z "$RT_REST" ]; then RT_REST=$_rt_pa_arg; else RT_REST="$RT_REST $_rt_pa_arg"; fi
                fi
                ;;
        esac
    done
    return 0
}

resolve_scope() {
    if [ -n "$RT_SCOPE" ]; then return 0; fi
    if [ -f /etc/rtctl/install.env ]; then
        RT_SCOPE='system'
        return 0
    fi
    home_dir
    if [ -f "$RT_HOME_DIR/.local/state/rtctl/install.env" ]; then
        RT_SCOPE='user'
        return 0
    fi
    if [ "$RT_EUID" = 0 ]; then RT_SCOPE='system'; else RT_SCOPE='user'; fi
    return 0
}

scope_paths() {
    if [ "$RT_SCOPE" = system ]; then
        RT_BIN_DIR="${RT_PREFIX:-/usr/local}/bin"
        RT_CONF_DIR='/etc/rtctl'
        RT_CONF='/etc/rtctl/agent.conf'
        RT_TLS_DIR='/etc/rtctl/tls'
        RT_STATE_DIR='/var/lib/rtctl'
        RT_STATE_FILE='/etc/rtctl/install.env'
        RT_LOG_DIR='/var/log/rtctl'
        RT_LOG_FILE='/var/log/rtctl/install.log'
        RT_SVC_LOG='/var/log/rtctl-agent.log'
        RT_PID_FILE='/run/rtctl-agent.pid'
        RT_UNIT='/etc/systemd/system/rtctl-agent.service'
        RT_RUN_USER='rtctl'
        RT_RUN_GROUP='rtctl'
    else
        home_dir
        _rt_sp_home=$RT_HOME_DIR
        RT_BIN_DIR="${RT_PREFIX:-$_rt_sp_home/.local}/bin"
        RT_CONF_DIR="$_rt_sp_home/.rtctl"
        RT_CONF="$_rt_sp_home/.rtctl/agent.conf"
        RT_TLS_DIR="$_rt_sp_home/.rtctl/tls"
        RT_STATE_DIR="$_rt_sp_home/.local/state/rtctl"
        RT_STATE_FILE="$RT_STATE_DIR/install.env"
        RT_LOG_DIR="$RT_STATE_DIR"
        RT_LOG_FILE="$RT_STATE_DIR/install.log"
        RT_SVC_LOG="$RT_STATE_DIR/rtctl-agent.log"
        RT_PID_FILE="$RT_STATE_DIR/rtctl-agent.pid"
        RT_UNIT="$_rt_sp_home/.config/systemd/user/rtctl-agent.service"
        RT_RUN_USER=$(id -un 2>/dev/null || printf 'unknown')
        RT_RUN_GROUP=$(id -gn 2>/dev/null || printf 'unknown')
    fi
    RT_BIN_AGENT="$RT_BIN_DIR/rtctl-agent"
    RT_BIN_CLIENT="$RT_BIN_DIR/rtctl"
    return 0
}

rt_init_defaults() {
    RT_TAB=$(printf '\t')
    RT_UID=$(id -u 2>/dev/null || printf '0')
    RT_EUID=$RT_UID
    RT_TTY=0
    RT_QUIET=0
    RT_JSON=0
    RT_VERBOSE=0
    RT_YES=0
    RT_SCOPE=''
    RT_PREFIX=''
    RT_PORT=''
    RT_LISTEN=''
    RT_ID=''
    RT_WS_PATH=''
    RT_TLS_GEN=0
    RT_TLS_CERT=''
    RT_TLS_KEY=''
    RT_ALLOW_SUDO=0
    RT_SUDO_MODE='ask'
    RT_PROXY_DOMAIN=''
    RT_BASE_URL=''
    RT_RELEASE=''
    RT_PINNED=''
    RT_NO_FIREWALL=0
    RT_ALLOW_FROM=''
    RT_FORCE=0
    RT_REVEAL=0
    RT_PURGE=0
    RT_CHECK=0
    RT_RESTART=0
    RT_TEMP=0
    RT_DETACHED=0
    RT_FOLLOW=0
    RT_NO_PRINT_TOKEN=0
    RT_INIT_FORCE=''
    RT_AGENT_SRC=''
    RT_PROXY=''
    RT_EDITOR_CMD=''
    RT_CMD=''
    RT_SUB=''
    RT_REST=''
    RT_INIT=''
    RT_LOCKED=0
    RT_TLS_ENABLED='false'
    RT_ALLOW_SUDO_STATE=0
    RT_FW_APPLIED='false'
    RT_FW_BACKEND=''
    RT_FW_RULE=''
    RT_FW_UNDO=''
    RT_AUTOSTART='none'
    RT_AGENT_VERSION='unknown'
    RT_AGENT_SHA256=''
    RT_TOKEN_FP=''
    RT_INSTALLED_AT=''
    RT_UPGRADED_AT=''
    RT_LAST_UPGRADE_RESULT=''
    RT_ROLLBACK_AT=''
    RT_ROLLBACK_FROM_VERSION=''
    RT_LAST_ERROR=''
    RT_PREV_BINARY=''
    RT_LISTEN_STATE=''
    RT_PORT_STATE=''
    RT_WS_PATH_STATE='/ws'
    RT_TLS_CERT_STATE=''
    RT_TLS_KEY_STATE=''
    RT_CAP_PRINT_TOKEN='false'
    RT_CAP_VERSION='false'
    RT_CAP_WS_PATH='false'
    RT_CAP_OPEN_FIREWALL='false'
    RT_CAP_FOREGROUND='false'
    RT_CAP_LOGS='false'
    RT_LOG_SOURCE=''
    RT_SVC_LOG=''
    RT_PID_FILE=''
    RT_DL_DIR=''
    RT_DL_AGENT=''
    RT_DL_CLIENT=''
    RT_DL_SCRIPT=''
    RT_TAG=''
    RT_ARCH=''
    RT_LOG_FILE=''
    RT_LOG_DIR=''
    RT_CONF_DIR=''
    RT_CONF=''
    RT_TLS_DIR=''
    RT_STATE_DIR=''
    RT_STATE_FILE=''
    RT_BIN_DIR=''
    RT_BIN_AGENT=''
    RT_BIN_CLIENT=''
    RT_UNIT=''
    RT_TMPFILE=''
    RT_HOME_DIR=''
    RT_PORT_PICKED=''
    RT_TAG_OUT=''
    RT_ARCH_OUT=''
    return 0
}

main() {
    rt_init_defaults
    rt_open_tty
    parse_args "$@"
    resolve_scope
    scope_paths
    if [ -z "$RT_CMD" ]; then
        RT_CMD='install'
    fi
    if [ "$RT_SCOPE" = system ] && [ "$RT_EUID" = 0 ]; then
        priv mkdir -p "$RT_LOG_DIR" 2>/dev/null || true
        priv chmod 0750 "$RT_LOG_DIR" 2>/dev/null || true
        priv chown root:root "$RT_LOG_DIR" 2>/dev/null || true
    fi
    rt_dispatch "$RT_CMD"
    exit $?
}

main "$@"
# RTCTL_SCRIPT_END
