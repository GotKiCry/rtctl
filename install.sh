#!/bin/sh
# ============================================================================
# rtctl 一键安装与管理脚本（Linux）—— 安装后命令名 rt
#
#   自举（推荐先落盘再执行）：
#     curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/Linux/bootstrap.sh \
#       -o /tmp/rt-install.sh && sudo sh /tmp/rt-install.sh install --scope system
#
#   便捷一行：
#     curl -fsSL https://raw.githubusercontent.com/GotKiCry/rtctl/Linux/bootstrap.sh | sudo sh -s -- --stable install --yes
#
#   无 sudo 的机器（用户级安装）：
#     sh /tmp/rt-install.sh install --scope user
#
# 硬约束（改这个文件前先读）：
#   1. 纯 POSIX sh：只用 set -eu；禁止 pipefail / 数组 / [[ ]] / local；
#      探测性管道一律 || true。
#   2. 交互只从 fd 3（/dev/tty）读；curl | sh 时 stdin 是脚本本体，
#      绝不从 stdin 读一个字节（无 tty 时全部走默认值）。
#   3. 单文件 + 命令注册表（name<TAB>handler）
#      驱动分发；未实现子命令统一 exit 11，未知子命令 exit 2。
#   4. 固定命令搜索 PATH；调用时收到的 PATH 仅用于安装提示；umask 077。
#   5. 原子替换：目标同目录 mktemp -> chmod/chown -> mv -f；SELinux 下 restorecon -F。
#   6. 凡写 agent.conf 必收尾 install -m 0600 -o rtctl -g rtctl；
#      /etc/rtctl 必须是 0750 root:rtctl 且先于 -init 创建。
# ============================================================================

set -eu
umask 077
RT_CALLER_PATH=${PATH-}
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
RT_SYSTEM_AGENT_LOG='/var/log/rtctl-agent/agent.log'
RT_RUN_USER='rtctl'
RT_RUN_GROUP='rtctl'
RT_BOOTSTRAP_URL='https://raw.githubusercontent.com/GotKiCry/rtctl/Linux/bootstrap.sh'
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

detail() {
    if [ "$RT_QUIET" = 1 ] || [ "$RT_VERBOSE" != 1 ]; then return 0; fi
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
    # 无控制终端（curl|sh、ssh 未加 -t、cron、CI）时，`exec 3</dev/tty` 的重定向错误
    # 属致命错误：严格 POSIX sh（dash / bash --posix）会直接退出非交互 shell（零输出 exit 1），
    # if 条件豁免也无法挽救。因此先用非特殊内建 true 探测——它的重定向失败只让该命令
    # 失败、不退出 shell；探测通过后再 exec 持有 fd 3。
    if [ -r /dev/tty ] && true 2>/dev/null 3</dev/tty; then
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
    RT_FW_APPLIED=$(state_get FW_APPLIED)
    RT_AUTOSTART=$(state_get AUTOSTART)
    RT_AGENT_VERSION=$(agent_version_of "$RT_BIN_AGENT")
    RT_AGENT_SHA256=$(state_get BINARY_SHA256)
    RT_TOKEN_FP=$(state_get TOKEN_FP)
    RT_INSTALLED_AT=$(state_get INSTALLED_AT)
    RT_LAST_ERROR=$(state_get LAST_ERROR)
    RT_LAST_UPGRADE_RESULT=$(state_get LAST_UPGRADE_RESULT)
    RT_UPGRADED_AT=$(state_get UPGRADED_AT)
    RT_ROLLBACK_AT=$(state_get ROLLBACK_AT)
    RT_ROLLBACK_FROM_VERSION=$(state_get ROLLBACK_FROM_VERSION)
    RT_PREV_BINARY=$(state_get PREV_BINARY)
    if [ -r "$RT_CONF" ]; then
        RT_LISTEN_STATE=$(conf_read_key listen)
        RT_LISTEN_STATE=${RT_LISTEN_STATE:-:8443}
        RT_PORT_STATE=$(port_from_listen "$RT_LISTEN_STATE")
    fi
    return 0
}

state_require() {
    if ! load_state; then
        if [ "$RT_SCOPE" = user ] && [ -d /etc/rtctl ]; then
            die "$EX_CONFLICT" "未检测到用户级安装（缺少 $RT_STATE_FILE）。系统级安装请用 sudo 并指定 --scope system"
        fi
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
    _rt_crv=$(sed -n "s/^[[:space:]]*${_rt_crk}[[:space:]]*=[[:space:]]*//p" "${2:-$RT_CONF}" 2>/dev/null | tail -n1 | sed 's/[[:space:]]*$//' || true)
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
    detail "已生成自签 CA 和服务器证书：$_rt_tg_dir"
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
    say 'TLS  : 已启用（自签 CA）'
    hint "将 CA 安全复制到控制机并命名为 rtctl-ca.crt：$_rt_tci_ca"
    hint '上面的连接命令已通过 -cafile 指定 CA，无需导入系统信任库'
    if [ "$RT_VERBOSE" = 1 ]; then
        info '可选：将 CA 导入控制机的系统信任库'
        hint "Debian/Ubuntu：sudo cp rtctl-ca.crt $RT_CA_IMPORT_DEBIAN && sudo update-ca-certificates"
        hint "RHEL/CentOS/Rocky/Fedora：sudo cp rtctl-ca.crt $RT_CA_IMPORT_RHEL && sudo update-ca-trust"
        hint 'Windows（管理员 PowerShell）：Import-Certificate -FilePath .\rtctl-ca.crt -CertStoreLocation Cert:\LocalMachine\Root'
    fi
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
        detail "运行用户已存在：$RT_RUN_USER"
    else
        _rt_eru_sh=$(nologin_shell)
        if have useradd; then
            priv useradd -r -M -d /nonexistent -s "$_rt_eru_sh" "$RT_RUN_USER" \
                || die "$EX_FAIL" "创建运行用户失败：$RT_RUN_USER"
        elif have adduser; then
            priv adduser -S -D -H -s /sbin/nologin "$RT_RUN_USER" \
                || die "$EX_FAIL" "创建运行用户失败：$RT_RUN_USER"
        else
            die "$EX_FAIL" "缺少 useradd/adduser，无法创建运行用户 $RT_RUN_USER"
        fi
        if ! run_user_exists; then
            die "$EX_FAIL" "运行用户创建后仍不可用：$RT_RUN_USER"
        fi
        detail "已创建运行用户：$RT_RUN_USER"
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
        detail "保留既有配置和 token：$RT_CONF"
        return 0
    fi
    [ -x "$RT_BIN_AGENT" ] || die "$EX_FAIL" "agent 不可执行：$RT_BIN_AGENT"
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
        err "初始化 agent 配置失败："
        sanitize_text <"$_rt_aic_err" >&2 || true
        rm -f "$_rt_aic_err" 2>/dev/null || true
        die "$EX_FAIL" "未生成配置文件：$RT_CONF"
    fi
    if [ -s "$_rt_aic_err" ]; then
        sanitize_text <"$_rt_aic_err" | while IFS= read -r _rt_aic_line; do
            log_line "init stderr: $_rt_aic_line"
        done
    fi
    rm -f "$_rt_aic_err" 2>/dev/null || true
    [ -f "$RT_CONF" ] || die "$EX_FAIL" "agent 未生成配置文件：$RT_CONF"
    conf_finish_perms "$RT_CONF"
    detail "已生成配置：$RT_CONF"
    return 0
}

# ---------------------------------------------------------------------------
# 版本解析与下载（只有 dev 查询使用 GitHub Releases API）
# ---------------------------------------------------------------------------
is_dev_release() {
    printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$'
}

stored_release_channel() {
    [ -n "$RT_STATE_DIR" ] && [ -f "$RT_STATE_DIR/release-channel" ] \
        && [ -r "$RT_STATE_DIR/release-channel" ] || return 1
    IFS= read -r _rt_src_channel <"$RT_STATE_DIR/release-channel" || return 1
    case "$_rt_src_channel" in
        stable|dev) printf '%s\n' "$_rt_src_channel" ;;
        *) return 1 ;;
    esac
}

upgrade_channel() {
    if ! stored_release_channel; then
        if is_dev_release "${1:-$RT_AGENT_VERSION}"; then
            printf '%s\n' dev
        else
            printf '%s\n' stable
        fi
    fi
}

resolve_dev_release() {
    rt_tmpfile
    _rt_rd_file=$RT_TMPFILE
    if ! dl_url "https://api.github.com/repos/$RT_REPO/releases?per_page=100" "$_rt_rd_file" 'Dev 版本列表'; then
        rm -f "$_rt_rd_file"
        die "$EX_DOWNLOAD" '无法查询 GitHub 测试版，请用 --release 指定已知的 dev 版本'
    fi
    # 只取 API 的 tag_name 字段。按版本号排序，避免重发旧版本时将其选为最新。
    RT_TAG_OUT=$(awk -F '"' '
        $2 == "tag_name" && $4 ~ /^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$/ {
            split(substr($4, 2), version, /[.-]/)
            print version[1], version[2], version[3], version[5], $4
        }
    ' "$_rt_rd_file" | LC_ALL=C sort -k1,1nr -k2,2nr -k3,3nr -k4,4nr | awk 'NR == 1 { print $5 }')
    rm -f "$_rt_rd_file"
    [ -n "$RT_TAG_OUT" ] || die "$EX_DOWNLOAD" '未找到已发布的 dev 测试版（标签格式 vX.Y.Z-dev.N）'
}

# resolve_release_tag —— 结果放 RT_TAG_OUT（必须在当前 shell 调用）
resolve_release_tag() {
    RT_TAG_OUT=''
    if [ -n "$RT_RELEASE" ]; then
        case "$RT_RELEASE" in
            *[!A-Za-z0-9.-]*) die "$EX_USAGE" '--release 格式为 vX.Y.Z 或 vX.Y.Z-dev.N' ;;
        esac
        if ! printf '%s\n' "$RT_RELEASE" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$'; then
            die "$EX_USAGE" '--release 格式为 vX.Y.Z 或 vX.Y.Z-dev.N'
        fi
        RT_TAG_OUT=$RT_RELEASE
        return 0
    fi
    _rt_rrt_channel=$RT_RELEASE_CHANNEL
    if [ -z "$_rt_rrt_channel" ]; then
        if [ "$RT_CMD" = upgrade ]; then
            _rt_rrt_channel=$(upgrade_channel)
        else
            _rt_rrt_channel=$(stored_release_channel || true)
        fi
    fi
    if [ "$_rt_rrt_channel" = dev ]; then
        resolve_dev_release
        return 0
    fi
    _rt_rrt_loc=''
    if [ "$RT_QUIET" = 0 ]; then printf '查询 Release 版本  %s/latest\n' "$RT_RELEASES" >&2; fi
    if have curl; then
        set -- -fsSI --max-time 20
        if [ -n "$RT_PROXY" ]; then set -- "$@" -x "$RT_PROXY"; fi
        _rt_rrt_loc=$(curl "$@" "$RT_RELEASES/latest" \
            | sed -n 's/^[Ll]ocation: //p' | tr -d '\r' | tail -n1 || true)
    fi
    if [ -z "$_rt_rrt_loc" ] && have wget; then
        _rt_rrt_loc=$(if [ -n "$RT_PROXY" ]; then export https_proxy="$RT_PROXY" http_proxy="$RT_PROXY"; fi
            wget -qS -T 20 --max-redirect=0 --spider "$RT_RELEASES/latest" 2>&1 \
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

dl_url() (
    _rt_du_url=$1
    _rt_du_dst=$2
    _rt_du_label=${3:-${_rt_du_url##*/}}
    _rt_du_display=$(printf '%s\n' "$_rt_du_url" | sed 's|://[^/@]*@|://***@|g; s/[?#].*$//')
    if [ "$RT_QUIET" = 0 ]; then printf '下载 %s  %s\n' "$_rt_du_label" "$_rt_du_display" >&2; fi
    if [ -n "$RT_PROXY" ]; then export https_proxy="$RT_PROXY" http_proxy="$RT_PROXY"; fi
    if have curl; then
        set -- curl -fSL --connect-timeout 15 --max-time 600 -o "$_rt_du_dst"
        if [ -n "$RT_PROXY" ]; then set -- "$@" -x "$RT_PROXY"; fi
        if [ "$RT_QUIET" = 0 ] && [ -t 2 ]; then set -- "$@" --progress-bar; else set -- "$@" -s; fi
    elif have wget; then
        set -- wget -T 30 -O "$_rt_du_dst"
        if [ "$RT_QUIET" = 1 ] || [ ! -t 2 ]; then set -- "$@" -q; fi
    else
        die "$EX_DOWNLOAD" "缺少 curl 与 wget，无法下载（可手动放置二进制后用 --agent-src）"
    fi
    if "$@" "$_rt_du_url"; then
        if [ "$RT_QUIET" = 0 ]; then printf '已下载 %s（%s 字节）\n' "$_rt_du_label" "$(wc -c <"$_rt_du_dst")" >&2; fi
    else
        _rt_du_rc=$?
        printf '下载 %s 失败（%s 退出码 %s）  %s\n' "$_rt_du_label" "$1" "$_rt_du_rc" "$_rt_du_display" >&2
        return "$_rt_du_rc"
    fi
)

sums_expected() {
    _rt_se_asset=$1
    _rt_se_sums=$2
    [ -f "$_rt_se_sums" ] || return 1
    tr -d '\r' <"$_rt_se_sums" | awk -v f="$_rt_se_asset" '{name=$2; sub(/^\*/, "", name); if (name == f) {print $1; exit}}'
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
    if ! dl_url "$_rt_fa_base/SHA256SUMS.txt" "$_rt_fa_sums"; then
        die "$EX_DOWNLOAD" "校验清单下载失败，安装已中止"
    fi
    if [ ! -s "$_rt_fa_sums" ]; then
        die "$EX_DOWNLOAD" "SHA256SUMS.txt 为空，请检查下载地址或代理返回的内容"
    fi
    _rt_fa_agent="$_rt_fa_dir/rtctl-agent-linux-$_rt_fa_arch"
    if ! dl_url "$_rt_fa_base/rtctl-agent-linux-$_rt_fa_arch" "$_rt_fa_agent"; then
        die "$EX_DOWNLOAD" "下载 agent 失败，请检查网络或使用 --proxy 指定代理"
    fi
    if ! check_elf "$_rt_fa_agent"; then
        die "$EX_CHECKSUM" "下载的 agent 不是有效的 Linux 二进制，可能收到错误页或架构不匹配"
    fi
    _rt_fa_rc=0
    verify_asset "$_rt_fa_agent" "rtctl-agent-linux-$_rt_fa_arch" "$_rt_fa_sums" || _rt_fa_rc=$?
    case "$_rt_fa_rc" in
        0) detail "agent SHA256 校验通过" ;;
        2) die "$EX_CHECKSUM" "校验清单缺少 rtctl-agent-linux-$_rt_fa_arch，安装已中止" ;;
        3) die "$EX_CHECKSUM" "缺少 SHA256 校验工具，安装已中止" ;;
        *) die "$EX_CHECKSUM" "agent SHA256 校验失败，文件可能损坏或版本不匹配" ;;
    esac
    RT_DL_AGENT=$_rt_fa_agent
    RT_DL_CLIENT=''
    _rt_fa_client="$_rt_fa_dir/rtctl-linux-$_rt_fa_arch"
    if dl_url "$_rt_fa_base/rtctl-linux-$_rt_fa_arch" "$_rt_fa_client" && check_elf "$_rt_fa_client"; then
        if verify_asset "$_rt_fa_client" "rtctl-linux-$_rt_fa_arch" "$_rt_fa_sums"; then
            RT_DL_CLIENT=$_rt_fa_client
            detail "客户端 rtctl 已下载并校验"
        else
            warn "客户端校验失败，将继续安装 agent，但本机 token 验证可能不可用"
        fi
    else
        warn "客户端下载失败，将继续安装 agent，但本机 token 验证可能不可用"
    fi
    RT_DL_SCRIPT=''
    _rt_fa_script="$_rt_fa_dir/install.sh"
    if dl_url "$_rt_fa_base/install.sh" "$_rt_fa_script" && [ -s "$_rt_fa_script" ]; then
        if verify_asset "$_rt_fa_script" "install.sh" "$_rt_fa_sums"; then
            RT_DL_SCRIPT=$_rt_fa_script
        else
            warn "install.sh 校验失败，将使用当前脚本"
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
        if have systemctl && [ -d /run/systemd/system ] && systemctl --user show-environment >/dev/null 2>&1; then
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
    _rt_ru_nnp='yes'
    if [ "$_rt_ru_allow_sudo" = 1 ]; then _rt_ru_nnp='no'; fi
    _rt_ru_tmp=$(rt_tmpfile && printf '%s' "$RT_TMPFILE") || return 1
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
        atomic_put "$_rt_ru_tmp" "$RT_UNIT" 0644 root:root || { rm -f "$_rt_ru_tmp"; err "写入服务单元失败：$RT_UNIT"; return 1; }
    else
        atomic_put "$_rt_ru_tmp" "$RT_UNIT" 0644 || { rm -f "$_rt_ru_tmp"; err "写入服务单元失败：$RT_UNIT"; return 1; }
    fi
    rm -f "$_rt_ru_tmp" 2>/dev/null || true
    detail "服务单元：$RT_UNIT（NoNewPrivileges=$_rt_ru_nnp${_rt_ru_extra}）"
    if [ "$RT_CAP_PRINT_TOKEN" != true ]; then
        warn "当前 agent 无法隐藏启动 token，完整 token 可能写入日志，请尽快升级"
    fi
    if [ "$RT_CAP_OPEN_FIREWALL" != true ]; then
        warn "当前 agent 无法关闭自动防火墙配置，每次启动可能尝试放行端口"
    fi
    if [ -n "$_rt_ru_ws" ] && [ "$_rt_ru_ws" != '/ws' ] && [ "$RT_CAP_WS_PATH" != true ]; then
        warn "当前 agent 不支持 -ws-path，将忽略 ws_path=$_rt_ru_ws 并继续使用 /ws"
    fi
}

render_openrc() {
    _rt_ro_tmp=$(rt_tmpfile && printf '%s' "$RT_TMPFILE") || return 1
    _rt_ro_extra=''
    if [ "$RT_CAP_PRINT_TOKEN" = true ]; then _rt_ro_extra="$_rt_ro_extra -print-token=false"; fi
    if [ "$RT_CAP_OPEN_FIREWALL" = true ]; then _rt_ro_extra="$_rt_ro_extra -open-firewall=false"; fi
    if [ "$RT_CAP_FOREGROUND" = true ]; then _rt_ro_extra="$_rt_ro_extra -foreground -log-file $RT_SVC_LOG"; fi
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
        || { rm -f "$_rt_ro_tmp"; err '写入 OpenRC 服务脚本失败：/etc/init.d/rtctl-agent'; return 1; }
    rm -f "$_rt_ro_tmp" 2>/dev/null || true
    ok "已渲染 OpenRC 服务：/etc/init.d/rtctl-agent"
}

prepare_agent_dirs() {
    [ "$RT_SCOPE" = system ] || return 0
    priv install -d -m 0755 -o root -g root "$RT_STATE_DIR" || return 1
    for _rt_pad_dir in "$RT_STATE_DIR/.rtctl" "${RT_SYSTEM_AGENT_LOG%/*}"; do
        [ ! -L "$_rt_pad_dir" ] || return 1
        priv install -d -m 0700 -o "$RT_RUN_USER" -g "$RT_RUN_GROUP" "$_rt_pad_dir" || return 1
    done
    RT_SVC_LOG=$RT_SYSTEM_AGENT_LOG
}

install_service_unit() {
    case "$RT_INIT" in
        systemd) render_unit "$RT_LISTEN_STATE" "$RT_WS_PATH_STATE" "$RT_ALLOW_SUDO_STATE" || return 1 ;;
        openrc) render_openrc || return 1 ;;
        nohup) info "无 init 系统：使用 nohup+pidfile 托管（容器/WSL）" ;;
        *) err "未知服务后端：$RT_INIT"; return 1 ;;
    esac
    RT_LOG_SOURCE='journald'
    if [ "$RT_INIT" = openrc ]; then RT_LOG_SOURCE=$RT_SVC_LOG; fi
    if [ "$RT_INIT" = nohup ]; then RT_LOG_SOURCE=$RT_SVC_LOG; fi
    if [ "$RT_CAP_FOREGROUND" = true ]; then RT_LOG_SOURCE=$RT_SVC_LOG; fi
}

svc_daemon_reload() {
    case "$RT_INIT" in
        systemd) systemctl_do daemon-reload >/dev/null 2>&1 ;;
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
            "$RT_BIN_AGENT"|"$RT_BIN_AGENT (deleted)") return 0 ;;
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

stop_for_replacement() {
    svc_active || return 0
    if [ "$RT_INIT" != systemd ]; then svc_stop; return $?; fi
    _rt_old_pid=$(systemctl_do show "$RT_SVC_NAME" -p MainPID --value) || return 1
    _rt_old_exe=$(priv readlink "/proc/$_rt_old_pid/exe" 2>/dev/null || true)
    case "${_rt_old_exe% (deleted)}" in
        "$RT_BIN_AGENT"|*/rtctl-agent|*/rtctl-agent-linux-amd64|*/rtctl-agent-linux-arm64) : ;;
        *) die "$EX_CONFLICT" "同名单元 $RT_SVC_NAME 的 PID $_rt_old_pid（${_rt_old_exe:-未知}）无法确认为旧 agent，请检查服务配置" ;;
    esac
    _rt_old_inode=$(priv stat -Lc '%d:%i' "/proc/$_rt_old_pid/exe") || return 1
    info "正在停止旧 agent（$RT_SVC_NAME，PID $_rt_old_pid）"
    systemctl_do stop "$RT_SVC_NAME" || return 1
    if [ "$(priv stat -Lc '%d:%i' "/proc/$_rt_old_pid/exe" 2>/dev/null || true)" = "$_rt_old_inode" ]; then
        err "旧 agent（PID $_rt_old_pid）仍在运行，检查 $RT_SVC_NAME 的 KillMode 配置"
        return 1
    fi
    return 0
}

svc_enable() {
    case "$RT_INIT" in
        systemd) systemctl_do enable "$RT_SVC_NAME" >/dev/null 2>&1 && RT_AUTOSTART='systemd' ;;
        openrc) rc-update add "$RT_SVC_NAME" default >/dev/null 2>&1 && RT_AUTOSTART='openrc' ;;
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
    if [ "$RT_INIT" = systemd ] && { [ "$RT_LOG_SOURCE" = journald ] || [ ! -s "$RT_SVC_LOG" ] || [ ! -r "$RT_SVC_LOG" ]; }; then
        if ! have journalctl; then die "$EX_FAIL" "缺少 journalctl，无法读取 journald 日志"; fi
        set -- -b -n 200 --no-pager
        if [ "$RT_SCOPE" = user ]; then set -- --user "$@"; fi
        if [ "$_rt_sl_follow" = 1 ]; then set -- "$@" -f; fi
        journalctl "$@" -u "$RT_SVC_NAME.service"
        return $?
    fi
    if [ ! -f "$RT_SVC_LOG" ]; then die "$EX_CONFLICT" "日志文件不存在：$RT_SVC_LOG"; fi
    if [ "$_rt_sl_follow" = 1 ]; then
        tail -n 200 -F "$RT_SVC_LOG"
    else
        tail -n 200 "$RT_SVC_LOG"
    fi
}

# ---------------------------------------------------------------------------
# 防火墙（仅读取状态并提供手工配置提示）
# ---------------------------------------------------------------------------
fw_read() {
    if LC_ALL=C "$@" 2>/dev/null; then return 0; fi
    if [ "$RT_EUID" != 0 ] && have sudo; then
        LC_ALL=C sudo -n -- "$@" 2>/dev/null
    else
        return 1
    fi
}

listen_is_loopback() {
    case "$1" in
        127.*:*|\[::1\]:*|localhost:*) return 0 ;;
        *) return 1 ;;
    esac
}

fw_check() {
    [ "$RT_NO_FIREWALL" = 0 ] && [ "$RT_QUIET" = 0 ] || return 0
    _rt_fw_port=$1
    case "$_rt_fw_port" in ''|*[!0-9]*) return 0 ;; esac
    if listen_is_loopback "$RT_LISTEN_STATE"; then
        info '防火墙：agent 仅监听本机，控制机应通过反向代理或隧道连接'
        return 0
    fi

    info "防火墙：从控制机验证 TCP $_rt_fw_port 是否可达"
    if have ufw && _rt_fw_status=$(fw_read ufw status) \
        && printf '%s\n' "$_rt_fw_status" | grep -q '^Status:[[:space:]]*active$'; then
        if printf '%s\n' "$_rt_fw_status" | awk -v port="$_rt_fw_port/tcp" '$1 == port && $2 == "ALLOW" { found=1 } END { exit !found }'; then
            hint "UFW 中存在 TCP $_rt_fw_port 的 ALLOW 条目，请检查来源范围"
        fi
        hint '查看 UFW 规则：sudo ufw status verbose'
        if [ -n "$RT_ALLOW_FROM" ]; then
            case "$RT_ALLOW_FROM" in
                *[!0-9a-fA-F:./]*) hint '请在 UFW 中使用有效的来源 IP 或 CIDR' ;;
                *) hint "按需放行：sudo ufw allow proto tcp from $RT_ALLOW_FROM to any port $_rt_fw_port" ;;
            esac
        else
            hint "按需放行（将 控制机IP 替换为实际 IP 或网段）：sudo ufw allow proto tcp from 控制机IP to any port $_rt_fw_port"
        fi
    elif have firewall-cmd && fw_read firewall-cmd --state | grep -qx running; then
        hint '查看 firewalld 区域：sudo firewall-cmd --get-active-zones'
        hint "查默认区域端口规则：sudo firewall-cmd --query-port=$_rt_fw_port/tcp"
        if fw_read firewall-cmd "--query-port=$_rt_fw_port/tcp" | grep -qx yes; then
            hint "firewalld 默认区域已配置 TCP $_rt_fw_port"
        fi
        if [ -z "$RT_ALLOW_FROM" ]; then
            hint "如使用默认区域：sudo firewall-cmd --permanent --add-port=$_rt_fw_port/tcp && sudo firewall-cmd --reload"
        fi
    elif have iptables; then
        hint '查看主机入站规则：sudo iptables -S INPUT'
        if fw_read iptables -C INPUT -p tcp --dport "$_rt_fw_port" -m comment --comment rtctl -j ACCEPT; then
            hint "发现旧版 rtctl 添加的 IPv4 放行规则：TCP $_rt_fw_port"
        fi
        if have ip6tables; then hint '查看 IPv6 入站规则：sudo ip6tables -S INPUT'; fi
        hint "需要放行时，请通过系统现有的防火墙配置管理 $_rt_fw_port/tcp 的持久规则"
    elif have nft; then
        hint '查看 nftables 规则：sudo nft list ruleset'
    else
        hint "请检查目标机防火墙和上游安全组是否允许 TCP $_rt_fw_port"
    fi
    if [ -n "$RT_ALLOW_FROM" ]; then
        hint "按来源放行，仅允许 $RT_ALLOW_FROM 访问 TCP $_rt_fw_port"
    fi
}

# ---------------------------------------------------------------------------
# 健康检查（/healthz；探活地址从 listen 推导）
# ---------------------------------------------------------------------------
health_probe() {
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
    if have curl; then
        _rt_hc_body=$(curl -fsS --noproxy '*' $_rt_hc_insecure --max-time 2 --max-filesize 4096 "$_rt_hc_url" 2>/dev/null) || return 1
    elif have wget; then
        set -- -q -T 2 -O -
        if [ "$_rt_hc_scheme" = https ]; then set -- "$@" --no-check-certificate; fi
        _rt_hc_body=$(no_proxy='*' NO_PROXY='*' wget "$@" "$_rt_hc_url" 2>/dev/null | head -c 16)
    else
        return 1
    fi
    [ "$_rt_hc_body" = ok ]
}

health_check() {
    _rt_hc_i=0
    while [ "$_rt_hc_i" -lt 10 ]; do
        if health_probe "$1"; then return 0; fi
        _rt_hc_i=$((_rt_hc_i + 1))
        if [ "$_rt_hc_i" -lt 10 ]; then sleep 1; fi
    done
    return 1
}
# ---------------------------------------------------------------------------
# 引导块（install 结尾 / connect 重放）
# ---------------------------------------------------------------------------
print_sudo_guide() {
    say ''
    info '远程 sudo（默认关闭）'
    hint "允许申请权限：$RT_NAME sudo enable    请求由本机 sudo 策略审批"
    hint "关闭授权：$RT_NAME sudo disable"
}

print_proxy_hint() {
    _rt_pph_domain=${1:-<你的域名>}
    say ''
    info '反向代理配置'
    hint "nginx：$RT_NAME proxy nginx --proxy-domain $_rt_pph_domain"
    hint "Caddy：$RT_NAME proxy caddy --proxy-domain $_rt_pph_domain"
}

print_guidance() {
    _rt_pg_listen=${RT_LISTEN_STATE:-}
    _rt_pg_port=${RT_PORT_STATE:-}
    _rt_pg_ws=${RT_WS_PATH_STATE:-/ws}
    _rt_pg_tls=${RT_TLS_ENABLED:-false}
    _rt_pg_status='未运行'
    if svc_active; then
        if health_probe "$_rt_pg_listen"; then _rt_pg_status='运行中'; else _rt_pg_status='未就绪'; fi
    fi
    _rt_pg_enabled='否'
    if svc_enabled; then _rt_pg_enabled='是'; fi
    _rt_pg_rt=$RT_NAME
    if [ "$RT_SCOPE" = system ]; then _rt_pg_rt="sudo $RT_NAME"; fi
    _rt_pg_token=$(token_value 2>/dev/null || true)
    hr
    info '连接信息'
    say "服务 : $_rt_pg_status（$RT_INIT），开机自启：$_rt_pg_enabled"
    say "监听 : $_rt_pg_listen"
    say "地址 : $(local_ips | tr '\n' ' ')"
    if [ -n "$_rt_pg_token" ]; then
        if [ -t 1 ] && [ "${RT_NO_PRINT_TOKEN:-0}" != 1 ] && [ "$RT_QUIET" != 1 ]; then
            say "token : $_rt_pg_token"
        else
            say "token : $(mask_token "$_rt_pg_token")"
        fi
        warn 'token 是远程控制凭据，请勿泄露'
        hint "查看完整 token：$_rt_pg_rt status"
    else
        hint "查看 token：$_rt_pg_rt status"
    fi
    say ''
    if listen_is_loopback "$_rt_pg_listen"; then
        say '在目标机本地验证连接：'
    else
        say '在 Linux 控制机下载客户端并验证连接：'
    fi
    _rt_pg_download="$RT_RELEASES/latest/download"
    if is_dev_release "$RT_AGENT_VERSION"; then
        _rt_pg_download="$RT_RELEASES/download/$RT_AGENT_VERSION"
    fi
    hint "curl -fsSL $_rt_pg_download/rtctl-linux-amd64 -o rtctl && chmod +x rtctl"
    case "$_rt_pg_listen" in
        :*|0.0.0.0:*|\[::\]:*) _rt_pg_ip=$(local_ips | head -n1) ;;
        *) _rt_pg_ip=${_rt_pg_listen%:*} ;;
    esac
    _rt_pg_ip=${_rt_pg_ip:-127.0.0.1}
    _rt_pg_ca=''
    if [ "$_rt_pg_tls" = true ] && [ -n "${RT_TLS_CERT_STATE:-}" ]; then
        _rt_pg_ca="$(dirname "$RT_TLS_CERT_STATE")/ca.crt"
    fi
    if [ "$_rt_pg_tls" = true ] && [ -n "$_rt_pg_ca" ] && [ -f "$_rt_pg_ca" ]; then
        hint "./rtctl -server wss://$_rt_pg_ip:$_rt_pg_port$_rt_pg_ws -cafile ./rtctl-ca.crt exec -token <token> -c 'uptime'"
    elif [ "$_rt_pg_tls" = true ]; then
        hint "./rtctl -server wss://$_rt_pg_ip:$_rt_pg_port$_rt_pg_ws exec -token <token> -c 'uptime'"
    elif [ "$_rt_pg_ws" = '/ws' ]; then
        hint "./rtctl $_rt_pg_ip:$_rt_pg_port <token> 'uptime'"
    else
        hint "./rtctl -server ws://$_rt_pg_ip:$_rt_pg_port$_rt_pg_ws exec -token <token> -c 'uptime'"
    fi
    say ''
    hint "状态：$_rt_pg_rt status    日志：$_rt_pg_rt logs -f"
    hint "配置：$_rt_pg_rt config edit    更多命令：$RT_NAME help"
    if [ "$_rt_pg_tls" = true ]; then
        if [ -n "$_rt_pg_ca" ] && [ -f "$_rt_pg_ca" ]; then
            tls_ca_import_hint "$_rt_pg_ca"
        else
            say 'TLS  : 已启用（wss）'
        fi
    else
        warn '当前未启用 TLS，token、命令和输出将明文传输'
        hint "公网或共享网络必须先启用 TLS：$_rt_pg_rt install --tls-generate"
    fi
    if [ -n "${RT_PROXY_DOMAIN:-}" ]; then
        print_proxy_hint "$RT_PROXY_DOMAIN"
    elif [ "$RT_VERBOSE" = 1 ]; then
        print_proxy_hint
    fi
    if [ "$RT_VERBOSE" = 1 ]; then print_sudo_guide; fi
    fw_check "$_rt_pg_port"
}

# ---------------------------------------------------------------------------
# token 读取
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

# 只编辑带 rtctl 标记的 PATH 行；跟随 dotfiles 的符号链接，保留原有配置。
update_path_profile() {
    _rt_pp_action=$1
    _rt_pp_file=$2
    if [ -L "$_rt_pp_file" ]; then
        _rt_pp_file=$(readlink -f "$_rt_pp_file") || return 1
    fi
    if [ -f "$_rt_pp_file" ]; then
        if [ "$_rt_pp_action" = install ] && priv grep -Fxq "$RT_PATH_LINE" "$_rt_pp_file"; then
            return 0
        fi
        if priv grep -q ' ;; esac # rtctl-managed PATH$' "$_rt_pp_file"; then
            priv sed -i '/ ;; esac # rtctl-managed PATH$/d' "$_rt_pp_file" || return 1
        elif [ "$_rt_pp_action" = remove ]; then
            return 0
        fi
    elif [ "$_rt_pp_action" = install ]; then
        _rt_pp_mask=077
        if [ "$RT_SCOPE" = system ]; then _rt_pp_mask=022; fi
        priv sh -c 'umask "$2"; set -C; : >"$1"' sh "$_rt_pp_file" "$_rt_pp_mask" || return 1
    fi
    if [ "$_rt_pp_action" = remove ]; then
        if [ "$2" = /etc/profile.d/rtctl-path.sh ] && [ -f "$2" ] && [ ! -s "$2" ]; then
            priv rm -f "$2" || return 1
        fi
        return 0
    fi
    priv sh -c '
        if [ -s "$1" ] && [ "$(tail -c 1 "$1" | wc -l)" -eq 0 ]; then
            printf "\n" >>"$1" || exit 1
        fi
        printf "%s\n" "$2" >>"$1"
    ' sh "$_rt_pp_file" "$RT_PATH_LINE"
}

configure_login_path() {
    _rt_lp_action=$1
    if [ "$_rt_lp_action" = install ]; then
        [ -x "$RT_BIN_DIR/$RT_NAME" ] || return 0
        _rt_lp_dir=$(CDPATH= cd -P "$RT_BIN_DIR" && pwd -P) || return 1
        case "$_rt_lp_dir" in *:*|*'
'*) warn '安装目录包含冒号或换行，无法加入 PATH'; return 1 ;; esac
        if [ "$RT_SCOPE" = system ]; then
            # 全局 PATH 也会被 root 使用。逐层检查实际目录，避免引入其他用户可写的位置。
            _rt_lp_parent=$_rt_lp_dir
            while [ -n "$_rt_lp_parent" ]; do
                _rt_lp_unsafe=$(find "$_rt_lp_parent" -prune \( ! -user root -o -perm -0020 -o -perm -0002 \) -print) || return 1
                if [ -n "$_rt_lp_unsafe" ]; then
                    warn "系统 PATH 要求目录归 root 所有且其他用户不可写：$_rt_lp_parent"
                    return 1
                fi
                _rt_lp_parent=${_rt_lp_parent%/*}
            done
        fi
        _rt_lp_quoted=$(printf '%s' "$_rt_lp_dir" | sed "s/'/'\\\\''/g")
        RT_PATH_LINE="case \":\${PATH-}:\" in *:'$_rt_lp_quoted':*) ;; *) export PATH=\"\${PATH:+\$PATH:}\"'$_rt_lp_quoted' ;; esac # rtctl-managed PATH"
    fi
    if [ "$RT_SCOPE" = system ]; then
        set -- /etc/profile.d/rtctl-path.sh
        if [ "$_rt_lp_action" = install ] && [ ! -d /etc/profile.d ]; then
            priv sh -c 'umask 022; mkdir -p /etc/profile.d' || return 1
        fi
        if [ -d /etc/zsh ]; then set -- "$@" /etc/zsh/zprofile
        elif [ -f /etc/zprofile ] || have zsh; then set -- "$@" /etc/zprofile
        fi
    else
        set -- "$RT_HOME_DIR/.profile"
        # Bash 登录时只读第一个存在的文件，创建 .bash_profile 会遮蔽原有 .profile。
        for _rt_lp_bash in "$RT_HOME_DIR/.bash_profile" "$RT_HOME_DIR/.bash_login"; do
            if [ -f "$_rt_lp_bash" ]; then set -- "$@" "$_rt_lp_bash"; fi
        done
        _rt_lp_zprofile="${ZDOTDIR:-$RT_HOME_DIR}/.zprofile"
        if [ -f "$_rt_lp_zprofile" ] || have zsh; then set -- "$@" "$_rt_lp_zprofile"; fi
    fi
    for _rt_lp_file do
        update_path_profile "$_rt_lp_action" "$_rt_lp_file" || {
            warn "无法更新 PATH 配置：$_rt_lp_file"
            return 1
        }
    done
}

cmd_install() {
    [ "$RT_SCOPE" = system ] && require_root_or_die
    if ! have curl && ! have wget; then
        die "$EX_DOWNLOAD" "缺少 curl 和 wget：请先安装其中一个（Debian/Ubuntu：apt install curl；Alpine：apk add curl）"
    fi
    if ! have sha256sum && ! have shasum && ! have openssl; then
        die "$EX_CHECKSUM" "缺少 SHA256 校验工具：请安装 sha256sum、shasum 或 openssl"
    fi
    if [ -n "$RT_PINNED" ]; then
        if [ ! -f "$0" ]; then
            die "$EX_USAGE" "通过管道执行时无法使用 --pinned-sha256：请先下载 install.sh 再执行"
        fi
        _rt_i_selfsha=$(sha256_of "$0" || true)
        if [ "$_rt_i_selfsha" != "$RT_PINNED" ]; then
            die "$EX_CHECKSUM" "install.sh 的 SHA256 不匹配：期望 $RT_PINNED，实际 $_rt_i_selfsha"
        fi
        detail "install.sh 的 SHA256 校验通过"
    fi
    lock_acquire

    # --- 步骤 1：环境预检 ---
    detail "[1/8] 检查安装环境"
    if ! detect_arch; then
        die "$EX_PLATFORM" "不支持的架构：$(uname -m)（支持 x86_64/amd64 和 aarch64/arm64，也可交叉编译后用 --agent-src 安装）"
    fi
    RT_ARCH=$RT_ARCH_OUT
    if [ "$RT_SCOPE" = system ] && [ "$RT_EUID" != 0 ]; then
        detail "安装器提权方式：sudo（$RT_SUDO_MODE）"
    fi
    if [ "$RT_SCOPE" = system ]; then
        priv sh -c 'umask 022; mkdir -p "$1"' sh "$RT_BIN_DIR" || die "$EX_FAIL" "无法创建 $RT_BIN_DIR"
        priv mkdir -p "$RT_LOG_DIR" 2>/dev/null || true
        priv chmod 0750 "$RT_LOG_DIR" 2>/dev/null || true
        priv chown root:root "$RT_LOG_DIR" 2>/dev/null || true
    else
        mkdir -p "$RT_BIN_DIR" || die "$EX_FAIL" "无法创建 $RT_BIN_DIR"
        mkdir -p "$RT_STATE_DIR" 2>/dev/null || true
    fi
    detail "平台：$(uname -s)/$RT_ARCH；安装范围：$RT_SCOPE"

    # --- 读取已有安装信息，下载校验期间保持服务运行 ---
    _rt_i_prev_scope=''
    if [ -f "$RT_STATE_FILE" ]; then
        _rt_i_prev_scope=$(sed -n 's/^SCOPE=//p' "$RT_STATE_FILE" 2>/dev/null | head -n1 || true)
        if [ -n "$_rt_i_prev_scope" ] && [ "$_rt_i_prev_scope" != "$RT_SCOPE" ]; then
            die "$EX_CONFLICT" "安装范围冲突：已安装为 $_rt_i_prev_scope，本次指定 $RT_SCOPE；请先执行 $RT_NAME uninstall"
        fi
        load_state
        detail "检测到既有安装，将保留配置和 token"
    else
        RT_INIT=$(detect_init)
    fi
    [ -n "$RT_INIT" ] || RT_INIT=$(detect_init)

    # --- 步骤 2：解析版本 ---
    detail "[2/8] 确定目标版本"
    resolve_release_tag
    RT_TAG=$RT_TAG_OUT
    _rt_i_scope_name='系统级'
    if [ "$RT_SCOPE" = user ]; then _rt_i_scope_name='用户级'; fi
    info "安装 $RT_TAG（Linux/$RT_ARCH，${_rt_i_scope_name}安装）"

    # --- 步骤 3/4：下载与校验 ---
    detail "[3/8] 下载安装文件"
    if [ -n "$RT_AGENT_SRC" ]; then
        [ -f "$RT_AGENT_SRC" ] || die "$EX_DOWNLOAD" "--agent-src 文件不存在：$RT_AGENT_SRC"
        RT_DL_AGENT=$RT_AGENT_SRC
        RT_DL_CLIENT=''
        RT_DL_SCRIPT=''
        RT_AGENT_SHA256=$(sha256_of "$RT_AGENT_SRC" || true)
        warn "使用本地 agent，未进行发布清单校验"
    else
        fetch_assets "$RT_TAG" "$RT_ARCH"
        RT_AGENT_SHA256=$(sha256_of "$RT_DL_AGENT" || true)
    fi
    detail "[4/8] 校验 SHA256"
    if [ -z "$RT_AGENT_SHA256" ]; then
        die "$EX_CHECKSUM" "无法计算 agent 的 SHA256，请检查校验工具"
    fi
    _rt_i_sha16=$(printf '%s' "$RT_AGENT_SHA256" | cut -c1-16 || true)
    detail "agent SHA256：${_rt_i_sha16}…"
    if [ -z "$RT_AGENT_SRC" ]; then ok "安装文件已下载并通过 SHA256 校验"; fi

    # --- 步骤 5/6：停旧服务 + 原子替换 ---
    detail "[5/8] 安装二进制和管理命令"
    info '正在安装文件并配置服务…'
    _rt_i_owner=''
    if [ "$RT_SCOPE" = system ]; then _rt_i_owner='root:root'; fi
    stop_for_replacement || die "$EX_SERVICE" "无法停止现有服务，安装已中止"
    install_one_binary "$RT_DL_AGENT" "$RT_BIN_AGENT" "$_rt_i_owner"
    detail "agent 已安装：$RT_BIN_AGENT"
    if [ -n "$RT_DL_CLIENT" ]; then
        install_one_binary "$RT_DL_CLIENT" "$RT_BIN_CLIENT" "$_rt_i_owner"
        detail "客户端已安装：$RT_BIN_CLIENT"
    elif [ -x "$RT_BIN_CLIENT" ]; then
        detail "沿用既有客户端：$RT_BIN_CLIENT"
    fi
    _rt_i_selfsrc=$(self_script_source || true)
    if manager_is_newer "$RT_TAG"; then
        info '保留较新的管理脚本'
    elif [ -n "$_rt_i_selfsrc" ]; then
        install_one_binary "$_rt_i_selfsrc" "$RT_BIN_DIR/$RT_NAME" "$_rt_i_owner"
        detail "管理命令已安装：$RT_BIN_DIR/$RT_NAME"
    else
        warn "无法安装管理命令：请将 install.sh 复制为 $RT_BIN_DIR/$RT_NAME"
    fi
    probe_agent_caps "$RT_BIN_AGENT"
    RT_AGENT_VERSION=$(agent_version_of "$RT_BIN_AGENT")

    # --- 步骤 7：运行用户、目录、配置、服务单元 ---
    detail "[6/8] 准备运行用户和配置"
    ensure_run_user
    prepare_agent_dirs || die "$EX_FAIL" '无法准备 agent 运行目录和日志目录'
    if [ "$RT_SCOPE" = system ]; then
        priv install -d -m 0750 -o root -g "$RT_RUN_GROUP" "$RT_CONF_DIR" \
            || die "$EX_FAIL" "创建配置目录失败：$RT_CONF_DIR"
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
        detail "保留既有端口：$RT_PORT_STATE"
        if [ -n "$RT_PORT" ] || [ -n "$RT_LISTEN" ]; then
            warn "已忽略 --port/--listen，继续使用 listen=$RT_LISTEN_STATE；修改请执行 $RT_NAME config set listen :<新端口> --restart"
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
        detail "已选择可用端口：$RT_PORT_STATE"
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
            die "$EX_FAIL" "TLS 证书与私钥不匹配"
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

    detail "[7/8] 配置 $RT_INIT 服务"
    if [ "$RT_INIT" = systemd ] && [ "$RT_SCOPE" = user ]; then
        priv mkdir -p "$(dirname "$RT_UNIT")" 2>/dev/null || true
    fi
    install_service_unit || die "$EX_SERVICE" '无法配置服务'
    svc_daemon_reload || die "$EX_SERVICE" '无法重新加载服务配置'

    detail "[8/8] 启动服务并做本机健康检查"
    [ -n "$RT_INSTALLED_AT" ] || RT_INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _rt_i_token=$(token_value 2>/dev/null || true)
    if [ -n "$_rt_i_token" ]; then RT_TOKEN_FP=$(fingerprint_of "$_rt_i_token"); fi
    # daemon-reload 不会重启旧进程；restart 同时覆盖 inactive 和正在自动重启的单元。
    if [ "$RT_INIT" = systemd ]; then _rt_i_start=svc_restart; else _rt_i_start=svc_start; fi
    if ! "$_rt_i_start"; then
        RT_LAST_ERROR='start failed'
        err "服务启动失败"
        hint "查看日志：$RT_NAME logs    查看状态：$RT_NAME status"
        state_write || true
        exit "$EX_SERVICE"
    fi
    if ! health_check "$RT_LISTEN_STATE" || ! svc_active; then
        RT_LAST_ERROR='healthz failed'
        warn "服务未就绪：请检查 $RT_INIT 服务和本机 $_rt_hc_url"
        hint "请执行 $RT_NAME logs，并检查本机监听和端口占用"
        state_write || true
        exit "$EX_HEALTH"
    fi
    svc_enable >/dev/null 2>&1 || true
    RT_LAST_UPGRADE_RESULT='ok'
    RT_LAST_ERROR=''
    state_write
    configure_login_path install || die "$EX_FAIL" "服务已安装，但无法持久化 PATH：$RT_BIN_DIR"
    ok "安装完成：rtctl-agent $RT_AGENT_VERSION"
    ok "本机健康检查通过"
    if [ -x "$RT_BIN_DIR/$RT_NAME" ]; then
        case ":$RT_CALLER_PATH:" in
            *":$RT_BIN_DIR:"*) : ;;
            *) hint "重新登录后可直接输入 $RT_NAME；当前终端可执行 $RT_BIN_DIR/$RT_NAME" ;;
        esac
    fi
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
    svc_start || die "$EX_SERVICE" "服务启动失败，请执行 $RT_NAME logs 查看日志"
    if ! health_check "$RT_LISTEN_STATE" || ! svc_active; then
        die "$EX_HEALTH" "服务未就绪，请执行 $RT_NAME logs 查看日志"
    fi
    ok "服务已启动"
    log_line 'action=start result=ok'
}

cmd_stop() {
    state_require
    svc_stop || die "$EX_SERVICE" "服务停止失败，请检查进程状态"
    ok "服务已停止"
    log_line 'action=stop result=ok'
}

cmd_restart() {
    state_require
    svc_restart || die "$EX_SERVICE" "服务重启失败，请执行 $RT_NAME logs 查看日志"
    if ! health_check "$RT_LISTEN_STATE" || ! svc_active; then
        die "$EX_HEALTH" "重启后健康检查未通过，请执行 $RT_NAME logs 查看日志"
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
    _rt_cs_status=inactive
    if svc_active; then
        _rt_cs_status='未就绪（服务管理器报告 active）'
        if [ -n "${RT_PORT_STATE:-}" ] && health_probe "$RT_LISTEN_STATE"; then _rt_cs_status=active; fi
    fi
    say "服务状态   : $_rt_cs_status"
    say "开机自启   : $(if svc_enabled; then printf 'enabled'; else printf 'disabled'; fi)"
    say "配置监听   : ${RT_LISTEN_STATE:-unknown}（端口 ${RT_PORT_STATE:-unknown}，ws_path ${RT_WS_PATH_STATE:-/ws}）"
    _rt_cs_pid=$(service_main_pid 2>/dev/null || true)
    if [ -n "$_rt_cs_pid" ] && [ "$_rt_cs_pid" != 0 ] && have ss; then
        _rt_cs_bound=$(ss -H -ltnp 2>/dev/null | awk -v p="pid=$_rt_cs_pid," 'index($0,p) {print $4}' | paste -sd ' ' -)
        if [ -n "$_rt_cs_bound" ]; then say "进程监听   : $_rt_cs_bound（PID $_rt_cs_pid）"; fi
    fi
    if running_image_differs; then warn '运行中的服务与磁盘上的 agent 二进制不一致'; fi
    say "agent 二进制: ${RT_BIN_AGENT:-unknown}（版本 ${RT_AGENT_VERSION:-unknown}）"
    say "配置文件   : ${RT_CONF:-unknown}"
    if [ -n "${RT_CONF:-}" ] && [ -f "$RT_CONF" ]; then
        say "配置权限   : $(priv stat -c '%a %U:%G' "$RT_CONF" 2>/dev/null || printf '?')"
    fi
    if [ -n "${RT_CONF_DIR:-}" ] && [ -d "$RT_CONF_DIR" ]; then
        say "配置目录   : $(priv stat -c '%a %U:%G' "$RT_CONF_DIR" 2>/dev/null || printf '?')"
    fi
    say "TLS        : ${RT_TLS_ENABLED:-unknown}"
    _rt_cs_token=$(token_value 2>/dev/null || true)
    if [ -n "$_rt_cs_token" ]; then RT_TOKEN_FP=$(fingerprint_of "$_rt_cs_token"); fi
    if [ "$RT_NO_PRINT_TOKEN" = 1 ]; then
        say 'token      : <已隐藏>'
    else
        say "token      : ${_rt_cs_token:-<不可读取>}"
    fi
    say "token 指纹 : ${RT_TOKEN_FP:-unknown}"
    say "安装时间   : ${RT_INSTALLED_AT:-未记录}"
    if [ -n "${RT_LAST_ERROR:-}" ]; then say "最近一次安装或升级错误 : $RT_LAST_ERROR"; fi
    if [ -n "${RT_PORT_STATE:-}" ]; then
        if port_in_use "$RT_PORT_STATE"; then
            say "端口占用   : 已被监听"
        else
            say "端口占用   : 未监听（服务可能未运行）"
        fi
    fi
    if [ "$_rt_cs_have" = 1 ]; then
        if [ "$_rt_cs_status" != active ]; then
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
    if [ "${RT_CAP_LOGS:-false}" = true ] && [ "$RT_LOG_SOURCE" = "$RT_SVC_LOG" ] && [ -s "$RT_SVC_LOG" ] && [ -r "$RT_SVC_LOG" ]; then
        set -- -logs -log-file "$RT_SVC_LOG" -lines 200
        if [ "${RT_FOLLOW:-0}" = 1 ]; then set -- "$@" -follow; fi
        "$RT_BIN_AGENT" "$@"
    else
        svc_logs "${RT_FOLLOW:-0}" | sanitize_text
    fi
}

cmd_enable() {
    state_require
    if svc_enabled; then info "开机自启已启用"; return 0; fi
    svc_enable || die "$EX_SERVICE" "启用开机自启失败"
    if [ "$RT_AUTOSTART" = none ]; then
        warn "当前环境无法设置开机自启：未找到支持的 init 或 cron"
    else
        ok "开机自启已启用（$RT_AUTOSTART）"
    fi
    state_write || true
    log_line 'action=enable result=ok'
}

cmd_disable() {
    state_require
    if ! svc_enabled; then info "开机自启已禁用"; return 0; fi
    svc_disable || die "$EX_SERVICE" "禁用开机自启失败"
    ok "开机自启已禁用"
    state_write || true
    log_line 'action=disable result=ok'
}

# ---------------------------------------------------------------------------
# upgrade：准备并校验 -> 备份 -> 停 -> 替换并验证 -> 失败时恢复并验证
# ---------------------------------------------------------------------------
manager_version() {
    sed -n "s/^RT_VERSION='\([^']*\)'$/\1/p" "$1" 2>/dev/null | head -n1
}

manager_is_newer() {
    [ -f "$RT_BIN_DIR/$RT_NAME" ] || return 1
    _rt_min_version=$(manager_version "$RT_BIN_DIR/$RT_NAME")
    awk -v manager="$_rt_min_version" -v target="$1" '
        BEGIN {
            if (manager !~ /^v[0-9]+\.[0-9]+\.[0-9]+($|-)/) exit 1
            split(substr(manager, 2), current, /[.-]/)
            split(substr(target, 2), next_version, /[.-]/)
            for (i = 1; i <= 3; i++) {
                if (current[i] + 0 != next_version[i] + 0)
                    exit !(current[i] + 0 > next_version[i] + 0)
            }
            if (current[4] == "" && next_version[4] != "") exit 0
            if (current[4] == "dev" && next_version[4] == "dev")
                exit !(current[5] + 0 > next_version[5] + 0)
            exit 1
        }
    '
}

service_main_pid() {
    case "$RT_INIT" in
        systemd) systemctl_do show "$RT_SVC_NAME" -p MainPID --value ;;
        nohup) cat "$RT_PID_FILE" ;;
        *) return 1 ;;
    esac
}

# 仅比较内核报告的可执行文件，不以 root 执行正在运行的进程映像。
running_image_differs() {
    _rt_img_pid=$(service_main_pid 2>/dev/null) || return 1
    _rt_img_inode=$(stat -Lc '%d:%i' "/proc/$_rt_img_pid/exe" 2>/dev/null) || return 1
    [ "$_rt_img_inode" != "$(stat -Lc '%d:%i' "$RT_BIN_AGENT" 2>/dev/null)" ]
}

upgrade_is_current() {
    [ "${RT_TAG#v}" = "${RT_AGENT_VERSION#v}" ] &&
        { [ "$(manager_version "$RT_BIN_DIR/$RT_NAME")" = "$RT_TAG" ] || manager_is_newer "$RT_TAG"; } &&
        ! running_image_differs
}

detach_run() {
    _rt_dr_sudo=''
    _rt_dr_user=''
    if [ "$RT_SCOPE" = system ]; then
        _rt_dr_sudo='sudo '
    else
        _rt_dr_user='--user'
    fi
    if [ "$RT_INIT" = systemd ] && have systemd-run; then
        _rt_dr_unit="rt-upgrade-$$.service"
        if systemd-run ${_rt_dr_user:+"$_rt_dr_user"} --unit="$_rt_dr_unit" --collect --quiet \
            --property=StandardOutput=journal --property=StandardError=journal -- "$@" >/dev/null 2>&1; then
            RT_UPGRADE_LOG_COMMAND="${_rt_dr_sudo}journalctl ${_rt_dr_user:+$_rt_dr_user }-u $_rt_dr_unit -f"
            return 0
        fi
    fi
    mkdir -p "$RT_LOG_DIR" || return 1
    ( : >>"$RT_LOG_FILE" ) || return 1
    RT_UPGRADE_LOG_COMMAND="${_rt_dr_sudo}tail -f '$RT_LOG_FILE'"
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
    if upgrade_is_current; then
        say "已是最新：$RT_TAG（当前 $_rt_u_cur）"
        return 0
    fi
    if [ "$RT_CHECK" = 1 ]; then
        say "可升级：$_rt_u_cur -> $RT_TAG"
        return 0
    fi
    if [ "${RT_DETACHED:-0}" != 1 ] && [ -f "$0" ]; then
        case "$0" in
            /*) _rt_u_script=$0 ;;
            *) _rt_u_script="$(pwd -P)/$0" ;;
        esac
        set -- upgrade --detached --yes --release "$RT_TAG" --scope "$RT_SCOPE"
        if [ -n "$RT_BASE_URL" ]; then set -- "$@" --base-url "$RT_BASE_URL"; fi
        if [ -n "$RT_PROXY" ]; then set -- "$@" --proxy "$RT_PROXY"; fi
        detach_run /bin/sh "$_rt_u_script" "$@" || die "$EX_SERVICE" "无法启动后台升级"
        ok "升级已在后台启动，当前会话可以安全退出"
        hint "升级日志：$RT_UPGRADE_LOG_COMMAND"
        _rt_u_status="$RT_NAME version --scope $RT_SCOPE"
        if [ "$RT_SCOPE" = system ]; then _rt_u_status="sudo $_rt_u_status"; fi
        hint "完成后确认版本：$_rt_u_status"
        return 0
    fi
    lock_acquire
    state_require
    if upgrade_is_current; then
        say "已是最新：$RT_TAG（当前 $RT_AGENT_VERSION）"
        return 0
    fi
    if ! detect_arch; then
        die "$EX_PLATFORM" "不支持的架构：$(uname -m)"
    fi
    RT_ARCH=$RT_ARCH_OUT
    info "正在下载并校验 $RT_TAG"
    fetch_assets "$RT_TAG" "$RT_ARCH"
    if ! manager_is_newer "$RT_TAG"; then
        [ -n "$RT_DL_SCRIPT" ] && [ "$(manager_version "$RT_DL_SCRIPT")" = "$RT_TAG" ] \
            || die "$EX_CHECKSUM" "未取得已校验的 $RT_TAG 管理脚本，旧服务仍在运行"
    fi
    _rt_u_newsha=$(sha256_of "$RT_DL_AGENT" || true)
    [ -n "$_rt_u_newsha" ] || die "$EX_CHECKSUM" '无法计算新 agent 的 SHA256，升级中止'
    prepare_agent_dirs || die "$EX_FAIL" '无法准备 agent 运行目录和日志目录，升级中止'
    _rt_u_owner=''
    if [ "$RT_SCOPE" = system ]; then _rt_u_owner='root:root'; fi
    RT_PREV_BINARY=''
    if [ -f "$RT_BIN_AGENT" ]; then
        atomic_put "$RT_BIN_AGENT" "$RT_BIN_AGENT.prev" 0755 "$_rt_u_owner" \
            || die "$EX_FAIL" '备份当前 agent 失败，升级中止'
        RT_PREV_BINARY="$RT_BIN_AGENT.prev"
    fi
    stop_for_replacement || die "$EX_SERVICE" '停止服务失败，升级中止'

    _rt_u_failure=''
    if ! atomic_put "$RT_DL_AGENT" "$RT_BIN_AGENT" 0755 "$_rt_u_owner"; then
        _rt_u_failure='无法替换 agent 二进制'
    else
        probe_agent_caps "$RT_BIN_AGENT"
        RT_AGENT_VERSION=$(agent_version_of "$RT_BIN_AGENT")
        RT_AGENT_SHA256=$_rt_u_newsha
        if [ "${RT_AGENT_VERSION#v}" != "${RT_TAG#v}" ]; then
            _rt_u_failure="agent 版本 $RT_AGENT_VERSION 与目标 $RT_TAG 不符"
        elif ! install_service_unit || ! svc_daemon_reload; then
            _rt_u_failure='无法加载新版本的服务配置'
        elif ! svc_start; then
            _rt_u_failure='新版本服务启动失败'
        elif ! health_check "$RT_LISTEN_STATE" || ! svc_active || running_image_differs; then
            _rt_u_failure='新版本未通过健康检查'
        fi
    fi
    if [ -z "$_rt_u_failure" ]; then
        if [ -n "$RT_DL_CLIENT" ]; then
            atomic_put "$RT_DL_CLIENT" "$RT_BIN_CLIENT" 0755 "$_rt_u_owner" || warn '客户端更新失败'
        fi
        if manager_is_newer "$RT_TAG"; then
            info '保留较新的管理脚本，仍可管理 dev 和 stable 渠道'
        elif ! atomic_put "$RT_DL_SCRIPT" "$RT_BIN_DIR/$RT_NAME" 0755 "$_rt_u_owner"; then
            RT_LAST_ERROR='管理脚本更新失败'
            RT_LAST_UPGRADE_RESULT='partial'
            state_write
            die "$EX_FAIL" "agent 已运行 $RT_AGENT_VERSION，管理脚本更新失败。请重试升级"
        fi
        RT_UPGRADED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
        RT_LAST_UPGRADE_RESULT='ok'
        RT_LAST_ERROR=''
        state_write
        configure_login_path install || die "$EX_FAIL" "服务已升级，但无法持久化 PATH：$RT_BIN_DIR"
        ok "升级完成：$RT_TAG"
        log_line "action=upgrade result=ok version=$RT_TAG"
        return 0
    fi
    warn "$_rt_u_failure，开始回滚"
    RT_LAST_UPGRADE_RESULT='rollback_failed'
    if [ -z "$RT_PREV_BINARY" ] || [ ! -f "$RT_PREV_BINARY" ]; then
        _rt_u_recovery_error='找不到旧版 agent 备份'
    elif ! atomic_put "$RT_PREV_BINARY" "$RT_BIN_AGENT" 0755 "$_rt_u_owner"; then
        _rt_u_recovery_error='无法恢复旧版 agent 二进制'
    else
        probe_agent_caps "$RT_BIN_AGENT"
        RT_AGENT_VERSION=$(agent_version_of "$RT_BIN_AGENT")
        RT_AGENT_SHA256=$(sha256_of "$RT_BIN_AGENT" || true)
        if ! install_service_unit || ! svc_daemon_reload; then
            _rt_u_recovery_error='无法加载旧版本的服务配置'
        elif ! svc_restart; then
            _rt_u_recovery_error='旧版本服务重启失败'
        elif ! health_check "$RT_LISTEN_STATE" || ! svc_active; then
            _rt_u_recovery_error='旧版本未通过健康检查'
        else
            RT_ROLLBACK_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
            RT_ROLLBACK_FROM_VERSION=$RT_TAG
            RT_LAST_UPGRADE_RESULT='rolled_back'
            RT_LAST_ERROR=$_rt_u_failure
            state_write
            log_line "action=upgrade result=rolled_back version=$RT_TAG"
            die "$EX_HEALTH" '升级失败，已恢复上一版本且本机健康检查通过'
        fi
    fi
    RT_LAST_ERROR="$_rt_u_failure；$_rt_u_recovery_error"
    state_write
    log_line "action=upgrade result=rollback_failed version=$RT_TAG"
    if [ -n "$RT_PREV_BINARY" ]; then hint "旧版本备份：$RT_PREV_BINARY"; fi
    die "$EX_HEALTH" "升级失败且未能恢复服务：$_rt_u_recovery_error。请检查 $RT_NAME logs"
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
        rt_tmpfile
        _rt_un_self=$RT_TMPFILE
        if cp "$0" "$_rt_un_self" 2>/dev/null; then
            chmod 0700 "$_rt_un_self" 2>/dev/null || true
            exec /bin/sh "$_rt_un_self" "$@"
        fi
        warn "无法把自身复制到 ${TMPDIR:-/tmp}，继续用当前进程执行（本次可完成，但脚本文件会被删除）"
    fi
    if [ "$RT_YES" != 1 ]; then
        say "将要移除：服务单元和二进制（配置默认保留）"
        if [ "$RT_PURGE" = 1 ]; then warn "--purge：还会销毁 agent.conf（含 token）与状态目录、专用用户"; fi
        if ! ask_yn '确认卸载？' 'n'; then
            say '已取消'
            return 0
        fi
    fi
    lock_acquire
    say '[1/6] 停止服务'
    svc_stop || warn "停止服务未成功，继续卸载"
    if svc_active; then
        warn "服务仍处于 active，先 disable 再继续（避免自动重启）"
    fi
    say '[2/6] 关闭开机自启'
    svc_disable >/dev/null 2>&1 || true
    say '[3/6] 清理失败状态'
    svc_reset_failed
    say '[4/6] 删除服务单元'
    svc_remove_unit
    say '[5/6] 删除二进制'
    configure_login_path remove || warn '部分 rtctl PATH 配置未能清理'
    for _rt_un_f in "$RT_BIN_AGENT" "$RT_BIN_AGENT.prev" "$RT_BIN_CLIENT" "$RT_BIN_CLIENT.prev" "$RT_BIN_DIR/$RT_NAME"; do
        if [ -n "$_rt_un_f" ] && [ -e "$_rt_un_f" ]; then
            priv rm -f "$_rt_un_f" && hint "已删除 $_rt_un_f"
        fi
    done
    if [ "${RT_FW_APPLIED:-false}" = true ] && [ -n "${RT_PORT_STATE:-}" ]; then
        hint "旧版安装记录了 ${RT_FW_BACKEND:-系统防火墙} 的 TCP $RT_PORT_STATE 放行规则，卸载后请在现有防火墙中检查并按需移除"
    fi
    say '[6/6] 处理配置与状态'
    priv rm -f "$RT_STATE_FILE" || die "$EX_FAIL" "无法移除安装状态文件：$RT_STATE_FILE"
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
            priv rmdir "${RT_SYSTEM_AGENT_LOG%/*}" 2>/dev/null || true
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
    if [ "$RT_SCOPE" = user ] && [ "$(sed -n '2s/^# rtctl user uid: //p' /usr/local/bin/rt 2>/dev/null || :)" = "$RT_UID" ]; then
        (as_root /bin/sh -c '
            if [ "$(sed -n "2s/^# rtctl user uid: //p" /usr/local/bin/rt)" = "$1" ]; then rm -f /usr/local/bin/rt; fi
        ' sh "$RT_UID") || warn '用户服务已卸载，管理员可清理共享入口 /usr/local/bin/rt'
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

valid_port() {
    case "$1" in ''|*[!0-9]*|??????*) return 1 ;; esac
    [ "$1" -gt 0 ] && [ "$1" -le 65535 ]
}

config_saved() {
    _rt_saved_ws=$RT_WS_PATH_STATE
    _rt_saved_sudo=$RT_ALLOW_SUDO_STATE
    RT_LISTEN_STATE=$(conf_read_key listen)
    RT_PORT_STATE=$(port_from_listen "$RT_LISTEN_STATE")
    RT_WS_PATH_STATE=$(conf_read_key ws_path)
    RT_WS_PATH_STATE=${RT_WS_PATH_STATE:-/ws}
    RT_TLS_CERT_STATE=$(conf_read_key tls_cert)
    RT_TLS_KEY_STATE=$(conf_read_key tls_key)
    RT_TLS_ENABLED=false
    if [ -n "$RT_TLS_CERT_STATE" ] && [ -n "$RT_TLS_KEY_STATE" ]; then RT_TLS_ENABLED=true; fi
    case "$(conf_read_key allow_sudo)" in true|TRUE|True|1) RT_ALLOW_SUDO_STATE=1 ;; *) RT_ALLOW_SUDO_STATE=0 ;; esac
    if [ "$_rt_saved_ws" != "$RT_WS_PATH_STATE" ] || [ "$_rt_saved_sudo" != "$RT_ALLOW_SUDO_STATE" ]; then
        install_service_unit && svc_daemon_reload || die "$EX_SERVICE" '配置已保存，服务单元更新失败'
    fi
    state_write
    if [ "$RT_RESTART" = 1 ]; then
        cmd_restart
    else
        hint "配置已保存，执行 $RT_NAME restart 后生效"
    fi
}

cmd_config() {
    _rt_cf_sub=${RT_SUB:-show}
    state_require
    case "$_rt_cf_sub" in set|edit) lock_acquire; state_require ;; esac
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
            hint "改配置：$RT_NAME config set <key> <value> [--restart]；查看完整 token：$RT_NAME status"
            ;;
        get)
            _rt_cf_key=${RT_REST%% *}
            [ -n "$_rt_cf_key" ] || die "$EX_USAGE" "用法：$RT_NAME config get <key>"
            _rt_cf_rc=0
            config_key_allowed "$_rt_cf_key" || _rt_cf_rc=$?
            case "$_rt_cf_rc" in
                0) : ;;
                2) die "$EX_NOSECRET" "查看完整 token 请执行 $RT_NAME status" ;;
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
            if [ "$_rt_cf_key" = port ]; then
                valid_port "$_rt_cf_rest" || die "$EX_USAGE" '端口必须是 1 到 65535 的整数'
                _rt_cf_key=listen
                _rt_cf_rest="${RT_LISTEN_STATE%:*}:$_rt_cf_rest"
            fi
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
                    *:*) valid_port "${_rt_cf_rest##*:}" || die "$EX_USAGE" '端口必须是 1 到 65535 的整数' ;;
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
                say "配置值未变化：$_rt_cf_key"
                if [ "$RT_RESTART" = 1 ]; then config_saved; fi
                return 0
            fi
            [ "$RT_SCOPE" = system ] && require_root_or_die
            if [ "$_rt_cf_key" = listen ] && [ "$RT_RESTART" = 1 ] && [ "${_rt_cf_rest##*:}" != "$RT_PORT_STATE" ] && port_in_use "${_rt_cf_rest##*:}"; then
                die "$EX_CONFLICT" "端口 ${_rt_cf_rest##*:} 已在使用，配置保持原值"
            fi
            conf_set_key "$_rt_cf_key" "$_rt_cf_rest"
            ok "已写入 $_rt_cf_key = $_rt_cf_rest"
            if [ "$_rt_cf_key" = listen ]; then hint "远程连接时请检查新端口的入站规则"; fi
            config_saved
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
                if ! "$_rt_cf_ed" "$_rt_cf_tmp" </dev/tty >/dev/tty 2>&1; then
                    rm -f "$_rt_cf_tmp"
                    die "$EX_FAIL" '编辑器退出失败，已放弃写入'
                fi
            else
                rm -f "$_rt_cf_tmp" 2>/dev/null || true
                die "$EX_USAGE" "config edit 需要交互终端（可改用 $RT_NAME config set <key> <value>）"
            fi
            _rt_cf_ok=1
            _rt_cf_listen=$(conf_read_key listen "$_rt_cf_tmp")
            case "$_rt_cf_listen" in
                *:*) valid_port "${_rt_cf_listen##*:}" || _rt_cf_ok=0 ;;
                *) _rt_cf_ok=0 ;;
            esac
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
            config_saved
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
    case "$RT_SUB" in
        '') cmd_help token; return ;;
        reset) : ;;
        *) die "$EX_USAGE" "查看完整 token 请执行 $RT_NAME status。轮换 token 请执行 $RT_NAME token reset" ;;
    esac
    state_require
    _rt_tk_rt=$RT_NAME
    if [ "$RT_SCOPE" = system ]; then _rt_tk_rt="sudo $RT_NAME"; fi
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
        die "$EX_FAIL" "无法生成新 token，请检查 openssl 和 /dev/urandom"
    fi
    conf_set_key token "$_rt_tr_new"
    if ! svc_restart; then
        warn "重启失败，正在恢复原 token"
        priv cp -p "$_rt_tr_bak" "$RT_CONF" || true
        conf_finish_perms "$RT_CONF"
        svc_restart >/dev/null 2>&1 || true
        die "$EX_SERVICE" "token 轮换失败，已恢复原 token"
    fi
    _rt_tr_newtok=$(token_value || true)
    if probe_token_ok "$_rt_tr_newtok"; then
        ok "新 token 验证通过"
    else
        _rt_tr_prc=$?
        case "$_rt_tr_prc" in
            2) warn "缺少本机客户端，未自动验证新 token，请在控制机验证" ;;
            3) warn "使用自签 TLS 时无法自动验证新 token，请在控制机验证" ;;
            *) warn "新 token 自动验证失败，请在控制机确认连接" ;;
        esac
    fi
    if [ -n "$_rt_tr_old" ] && probe_token_ok "$_rt_tr_old"; then
        warn "旧 token 仍然可用，请确认 agent 已重启"
    fi
    say "新 token = $(mask_token "$_rt_tr_newtok")  指纹=$(fingerprint_of "$_rt_tr_newtok")"
    hint "查看完整 token：$_rt_tk_rt status"
    hint "备份包含旧 token：$_rt_tr_bak"
    if [ "$RT_SCOPE" = system ]; then
        hint "删除备份：sudo shred -u $_rt_tr_bak"
    else
        hint "删除备份：shred -u $_rt_tr_bak"
    fi
    log_line 'action=token.reset result=ok'
    return 0
}

# ---------------------------------------------------------------------------
# sudo：允许 agent 请求已有的 OS 权限
# ---------------------------------------------------------------------------
cmd_sudo() {
    _rt_sd_sub=${RT_SUB:-status}
    state_require
    case "$_rt_sd_sub" in
        enable|temp|disable)
            if [ "$_rt_sd_sub" = disable ]; then _rt_sd_value=false; else _rt_sd_value=true; fi
            conf_set_key allow_sudo "$_rt_sd_value"
            RT_RESTART=1
            config_saved
            ok "sudo 请求设置已应用：$_rt_sd_value"
            ;;
        status)
            say "服务账号   : $RT_RUN_USER"
            say "允许申请 sudo : $(conf_read_key allow_sudo)"
            if [ "$RT_RUN_USER" = root ]; then
                hint '服务已使用 root 身份，无需申请 sudo'
            else
                hint '普通命令使用服务账号权限。sudo 请求由本机 sudo 策略审批。'
            fi
            ;;
        *)
            die "$EX_USAGE" "用法：$RT_NAME sudo status|temp|enable|disable"
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
        # 期望值按 scope：system=600 rtctl:rtctl；user=600 <运行用户>（conf_finish_perms 决定）
        _rt_dc_want_conf='600 rtctl:rtctl'
        if [ "$RT_SCOPE" = user ]; then
            _rt_dc_want_conf="600 $RT_RUN_USER:$RT_RUN_GROUP"
        fi
        _rt_dc_perm=$(priv stat -c '%a %U:%G' "$RT_CONF" 2>/dev/null || printf '?')
        case "$_rt_dc_perm" in
            "$_rt_dc_want_conf") doctor_ok "配置权限：$_rt_dc_perm" ;;
            *) doctor_warn "配置权限异常：$_rt_dc_perm（期望 $_rt_dc_want_conf）" ;;
        esac
        _rt_dc_tok=$(token_value || true)
        if [ -n "$_rt_dc_tok" ]; then doctor_ok "token 可读（fingerprint=$(fingerprint_of "$_rt_dc_tok")）"; else doctor_warn "token 读不到（无权限？）"; fi
    else
        doctor_bad "配置文件缺失：${RT_CONF:-<未知>}"
    fi
    if [ -d "${RT_CONF_DIR:-/nonexistent}" ]; then
        # 期望值按 scope：system=750/710 root:rtctl；user=700 <运行用户>（目录含 token 文件名）
        _rt_dc_want_dir='750 root:rtctl'
        _rt_dc_want_dir2='710 root:rtctl'
        if [ "$RT_SCOPE" = user ]; then
            _rt_dc_want_dir="700 $RT_RUN_USER:$RT_RUN_GROUP"
            _rt_dc_want_dir2=''
        fi
        _rt_dc_dperm=$(priv stat -c '%a %U:%G' "$RT_CONF_DIR" 2>/dev/null || printf '?')
        case "$_rt_dc_dperm" in
            "$_rt_dc_want_dir"|"$_rt_dc_want_dir2") doctor_ok "配置目录权限：$_rt_dc_dperm" ;;
            *) doctor_warn "配置目录权限异常：$_rt_dc_dperm（期望 $_rt_dc_want_dir）" ;;
        esac
    fi
    if ! svc_active; then doctor_bad "服务未运行（$RT_NAME start，排错 $RT_NAME logs）"
    elif health_probe "$RT_LISTEN_STATE"; then doctor_ok "服务 active，本机 /healthz 已就绪（$RT_INIT）"
    else doctor_bad "服务管理器报告 active，本机 /healthz 未就绪（排错 $RT_NAME logs）"
    fi
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
            doctor_warn "allow_sudo=true：允许已认证的客户端向本机申请 sudo"
            if [ -f "$RT_SUDOERS_AGENT" ]; then doctor_warn "$RT_SUDOERS_AGENT 存在（永久授权，等价 root 通道）"; else doctor_ok "未写 sudoers（临时授权形态）"; fi
            if [ -f "${RT_UNIT:-}" ]; then
                if grep -q '^NoNewPrivileges=yes' "$RT_UNIT" 2>/dev/null; then
                    doctor_bad "allow_sudo=true 但 unit 里 NoNewPrivileges=yes：sudo 会被拦（重跑 $RT_NAME sudo enable）"
                fi
            fi
            ;;
        *)
            if [ -f "$RT_SUDOERS_AGENT" ]; then
                doctor_warn "请管理员检查旧版免密配置 $RT_SUDOERS_AGENT"
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
    fw_check "$RT_PORT_STATE"
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

cmd_channel() {
    case "${RT_SUB:-show}" in
        show)
            say "当前渠道：$(upgrade_channel "$(state_get AGENT_VERSION)")"
            ;;
        stable|dev)
            [ "$RT_SCOPE" != system ] || require_root_or_die
            rt_tmpfile
            _rt_ch_file=$RT_TMPFILE
            printf '%s\n' "$RT_SUB" >"$_rt_ch_file"
            if ! atomic_put "$_rt_ch_file" "$RT_STATE_DIR/release-channel" 0644; then
                rm -f "$_rt_ch_file"
                die "$EX_FAIL" '无法保存渠道设置'
            fi
            rm -f "$_rt_ch_file"
            ok "已切换到 $RT_SUB 渠道"
            ;;
        *) die "$EX_USAGE" "用法：$RT_NAME channel [show|stable|dev]" ;;
    esac
}

menu_run() (
    set -- "$@" --scope "$RT_SCOPE"
    if [ -n "$RT_PREFIX" ]; then set -- "$@" --prefix "$RT_PREFIX"; fi
    if [ "$RT_SCOPE" = system ]; then
        as_root /bin/sh "$RT_MENU_SCRIPT" "$@"
    else
        /bin/sh "$RT_MENU_SCRIPT" "$@"
    fi
)

cmd_menu() {
    if [ "$RT_TTY" != 1 ] || [ ! -t 0 ] || [ ! -t 1 ] || [ "$RT_QUIET" = 1 ]; then
        cmd_help
        return
    fi
    case "$0" in
        /*) RT_MENU_SCRIPT=$0 ;;
        *) RT_MENU_SCRIPT="$(pwd -P)/$0" ;;
    esac

    while :; do
        if ! _rt_menu_channel=$(stored_release_channel); then
            if [ "$RT_SCOPE" = system ] && [ "$RT_EUID" != 0 ] && [ ! -r "$RT_CONF_DIR" ]; then
                _rt_menu_channel='自动'
            else
                _rt_menu_channel=$(upgrade_channel "$(state_get AGENT_VERSION)")
            fi
        fi
        say ''
        if load_state; then
            info "管理脚本 $RT_VERSION  |  agent $RT_AGENT_VERSION  |  配置监听 $RT_LISTEN_STATE"
        else
            info "管理脚本 $RT_VERSION"
        fi
        say "范围 $RT_SCOPE  |  渠道 $_rt_menu_channel"
        say '  1  状态'
        say '  2  连接信息'
        say '  3  日志'
        say '  4  切换渠道'
        say '  5  检查更新'
        say '  6  升级到所选渠道'
        say '  7  卸载'
        say '  8  修改配置'
        say '  0  退出'
        printf '请选择：' >&2
        IFS= read -r _rt_menu_choice <&3 || return 0
        case "$_rt_menu_choice" in
            1) set -- status ;;
            2) set -- connect --no-print-token ;;
            3) set -- logs ;;
            4)
                say '  1  stable'
                say '  2  dev'
                say '  0  返回'
                printf '选择渠道：' >&2
                IFS= read -r _rt_menu_channel_choice <&3 || return 0
                case "$_rt_menu_channel_choice" in
                    1|stable) set -- channel stable ;;
                    2|dev) set -- channel dev ;;
                    0|'') continue ;;
                    *) err '请输入 1、2 或 0'; continue ;;
                esac
                ;;
            5) set -- upgrade --check ;;
            6) set -- upgrade --wait ;;
            7) set -- uninstall ;;
            8)
                say '  1  查看配置'
                say '  2  修改端口并重启'
                say '  3  编辑配置文件'
                say '  4  应用配置并重启'
                say '  0  返回'
                printf '选择操作：' >&2
                IFS= read -r _rt_menu_action <&3 || return 0
                case "$_rt_menu_action" in
                    1) set -- config show ;;
                    2)
                        printf '新端口（1–65535，回车取消）：' >&2
                        IFS= read -r _rt_menu_port <&3 || return 0
                        [ -n "$_rt_menu_port" ] || continue
                        valid_port "$_rt_menu_port" || { err '请输入 1 到 65535 的整数'; continue; }
                        set -- config set port "$_rt_menu_port" --restart ;;
                    3) set -- config edit ;;
                    4) set -- restart ;;
                    0|'') continue ;;
                    *) err '请输入 0 到 4'; continue ;;
                esac ;;
            0|q|exit) return 0 ;;
            '') continue ;;
            *) err '请输入 0 到 8'; continue ;;
        esac
        if menu_run "$@"; then
            if [ "$1" = uninstall ] && [ ! -f "$RT_MENU_SCRIPT" ]; then return 0; fi
            if [ "$1" = upgrade ] && [ "$2" = --wait ] && [ "$(manager_version "$RT_MENU_SCRIPT")" != "$RT_VERSION" ]; then
                set -- menu --scope "$RT_SCOPE"
                if [ -n "$RT_PREFIX" ]; then set -- "$@" --prefix "$RT_PREFIX"; fi
                exec /bin/sh "$RT_MENU_SCRIPT" "$@"
            fi
        else
            _rt_menu_rc=$?
            err "$RT_NAME $1 退出码：$_rt_menu_rc"
        fi
    done
}

cmd_help() {
    case "${1:-}" in
        '') : ;;
        install)
            say "用法  $RT_NAME install [选项]"
            say '  --scope system|user  --prefix DIR  --init systemd|openrc|nohup'
            say '  --port N  --listen ADDR  --id NAME  --ws-path PATH'
            say '  --tls-generate 或 --tls-cert FILE --tls-key FILE'
            say '  --dev | --stable | --release TAG'
            say '  --agent-src FILE  --base-url URL  --proxy URL  --pinned-sha256 HEX'
            say '  --no-print-token  --no-firewall  --allow-from CIDR  --proxy-domain DOMAIN'
            say '  --allow-sudo  --sudo ask|nopasswd  --verbose'
            return
            ;;
        upgrade)
            say "用法  $RT_NAME upgrade [选项]"
            say '  --dev | --stable | --release TAG'
            say '  --check  只检查版本'
            say '  --wait   在当前终端等待升级结束'
            say '  --scope system|user  --base-url URL  --proxy URL  --verbose'
            return
            ;;
        init)
            say "用法  $RT_NAME init [选项]"
            say '  生成 agent 配置和 token'
            say '  --scope system|user  --prefix DIR  --port N  --listen ADDR  --id NAME'
            say '  --ws-path PATH  --tls-cert FILE  --tls-key FILE  --allow-sudo'
            return
            ;;
        status)
            say "用法  $RT_NAME status [--scope system|user] [--no-print-token] [--verbose]"
            say '  查看服务状态、端口、版本和完整 token'
            say '  --no-print-token  隐藏完整 token'
            return
            ;;
        logs)
            say "用法  $RT_NAME logs [--scope system|user] [-f|--follow]"
            say '  查看 agent 日志，-f 持续跟随'
            return
            ;;
        connect|doctor)
            say "用法  $RT_NAME $1 [--scope system|user] [--no-firewall] [--allow-from CIDR] [--verbose]"
            if [ "$1" = connect ]; then
                say '  --no-print-token  隐藏完整 token'
            fi
            return
            ;;
        uninstall)
            say "用法  $RT_NAME uninstall [--scope system|user] [--yes] [--purge]"
            say '  --purge  同时删除配置和 token'
            return
            ;;
        start|stop|restart|enable|disable)
            say "用法  $RT_NAME $1 [--scope system|user]"
            return
            ;;
        config)
            say "用法  $RT_NAME config [子命令] [--scope system|user]"
            say '  show                          查看配置（默认）'
            say '  get <key>                     读取配置项'
            say '  set <key> <value> [--restart]   修改配置项'
            say '  set port <1–65535> [--restart]  仅修改端口，保留监听地址'
            say '  edit [--editor CMD] [--restart] 编辑配置文件'
            return
            ;;
        token)
            say "用法  $RT_NAME token <子命令>"
            say '  reset [--yes] [--scope system|user]  轮换 token'
            say "查看完整 token 请执行 $RT_NAME status"
            return
            ;;
        sudo)
            say "用法  $RT_NAME sudo [子命令] [--scope system|user]"
            say '  status                 查看远程 sudo 状态（默认）'
            say '  enable | temp          允许申请 sudo，由系统审批'
            say '  disable                关闭远程 sudo'
            return
            ;;
        proxy)
            say "用法  $RT_NAME proxy [子命令] [--proxy-domain DOMAIN] [--scope system|user]"
            say '  nginx   生成 Nginx 配置（默认）'
            say '  caddy   生成 Caddy 配置'
            return
            ;;
        version)
            say "用法  $RT_NAME version [--scope system|user] [--json]"
            return
            ;;
        menu)
            say "用法  $RT_NAME menu [--scope system|user]"
            say '  状态、连接信息、日志、渠道切换、检查更新、升级、卸载、修改配置'
            return
            ;;
        channel)
            say "用法  $RT_NAME channel [子命令] [--scope system|user]"
            say '  show     查看当前渠道（默认）'
            say '  stable   选择稳定版渠道'
            say '  dev      选择测试版渠道'
            return
            ;;
        help)
            say "用法  $RT_NAME help [命令] [--verbose]"
            return
            ;;
        harden|backup|restore|migrate)
            say "$RT_NAME $1 尚未实现"
            return
            ;;
        *) die "$EX_USAGE" "未知命令：$1，请运行 $RT_NAME help" ;;
    esac

    say "rtctl $RT_VERSION —— Linux 安装与管理（命令：$RT_NAME）"
    say ''
    say "用法：$RT_NAME <命令> [子命令] [选项]"
    say ''
    say '常用命令：'
    say '  menu          打开互动菜单'
    say '  install       安装或覆盖升级，保留既有配置和 token'
    say '  status        查看服务、端口、版本和完整 token'
    say '  connect       查看连接信息和客户端命令'
    say '  logs          查看日志，-f 持续跟随'
    say '  doctor        检查安装与安全配置'
    say ''
    say '服务管理：'
    say '  start | stop | restart    启动、停止或重启服务'
    say '  enable | disable          启用或关闭开机自启'
    say '  upgrade                   升级，失败时回滚'
    say '  channel show | stable | dev   查看或切换升级渠道'
    say '  uninstall                 卸载；--purge 同时删除配置和 token'
    say ''
    say '配置与安全：'
    say '  config show | get | set | edit    查看或修改配置'
    say '  token reset                       轮换 token'
    say '  sudo status | temp | enable | disable    管理远程 sudo'
    say '  proxy nginx | caddy               生成反向代理配置'
    say '  init                              仅生成配置和 token'
    say '  version                           查看版本信息'
    say ''
    say '常用选项：'
    say '  --scope system|user    指定要维护的旧实例，新安装使用用户服务'
    say '  --tls-generate         生成自签 CA 和服务器证书'
    say '  --no-print-token       隐藏完整 token'
    say '  --no-firewall          跳过防火墙检查和提示'
    say '  --dev | --stable       安装或升级时选择 dev 测试版或稳定版'
    say '  --release TAG          安装或升级到指定版本'
    say '  --wait                 升级时等待完成并直接显示结果'
    say '  --yes  --quiet  --verbose'
    say ''
    say "示例：$RT_NAME install --tls-generate"
    say "      $RT_NAME upgrade --dev --check"
    say "      $RT_NAME status"
    say "      $RT_NAME sudo status"
    say ''
    say "命令帮助  $RT_NAME <命令> --help 或 $RT_NAME help <命令>"
    if [ "$RT_VERBOSE" != 1 ]; then
        say ''
        say "完整选项和退出码：$RT_NAME help --verbose"
        return 0
    fi
    say ''
    say '完整选项（按命令支持）：'
    say '  --prefix DIR  --port N  --listen ADDR  --id NAME  --ws-path /rt/ws'
    say '  --tls-cert FILE --tls-key FILE  --allow-sudo  --sudo ask|nopasswd'
    say '  --proxy-domain DOMAIN  --base-url URL  --agent-src FILE'
    say '  --pinned-sha256 HEX  --proxy URL'
    say '  --allow-from CIDR    在手工防火墙提示中指定来源网段'
    say '  --init systemd|openrc|nohup  --json'
    say ''
    say '退出码：'
    say '  0 成功；1 通用失败；2 用法错误；3 平台不支持；4 下载失败；5 校验失败'
    say '  6 权限不足；7 服务操作失败；8 配置冲突；9 健康检查失败；10 自检未通过'
    say '  11 功能未实现；12 拒绝输出敏感内容；75 另一个安装或升级正在进行'
    print_sudo_guide
    return 0
}

cmd_not_implemented() {
    _rt_ni=${RT_CMD:-unknown}
    err "功能 $_rt_ni 尚未实现（计划在后续版本落地）"
    hint "当前可用命令：$RT_NAME help"
    exit "$EX_UNIMPL"
}

# ---------------------------------------------------------------------------
# 命令注册表：name<TAB>handler
# ---------------------------------------------------------------------------
rt_cmd_table() {
    cat <<'RTCTL_CMD_TABLE'
install	cmd_install
init	cmd_init
start	cmd_start
stop	cmd_stop
restart	cmd_restart
status	cmd_status
logs	cmd_logs
enable	cmd_enable
disable	cmd_disable
upgrade	cmd_upgrade
uninstall	cmd_uninstall
config	cmd_config
token	cmd_token
sudo	cmd_sudo
proxy	cmd_proxy
doctor	cmd_doctor
connect	cmd_connect
version	cmd_version
menu	cmd_menu
channel	cmd_channel
help	cmd_help
harden	cmd_not_implemented
backup	cmd_not_implemented
restore	cmd_not_implemented
migrate	cmd_not_implemented
RTCTL_CMD_TABLE
}

rt_dispatch() {
    _rt_dp_cmd=$1
    shift || true
    _rt_dp_handler=''
    while IFS="$RT_TAB" read -r _rt_dp_name _rt_dp_h; do
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
    "$_rt_dp_handler" "$@"
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
            --dev|--stable)
                _rt_pa_channel=${_rt_pa_arg#--}
                if [ -n "$RT_RELEASE_CHANNEL" ] && [ "$RT_RELEASE_CHANNEL" != "$_rt_pa_channel" ]; then
                    die "$EX_USAGE" '--dev 和 --stable 只能选择一个'
                fi
                RT_RELEASE_CHANNEL=$_rt_pa_channel
                ;;
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
            --temp) RT_TEMP=1 ;;
            --detached|--wait) RT_DETACHED=1 ;;
            --follow|-f) RT_FOLLOW=1 ;;
            --no-print-token) RT_NO_PRINT_TOKEN=1 ;;
            -h|--help) RT_HELP=1 ;;
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

legacy_system_installed() {
    [ -f /etc/rtctl/install.env ] || [ -f /etc/systemd/system/rtctl-agent.service ] ||
        [ -f /etc/init.d/rtctl-agent ] || { [ -d /etc/rtctl ] && [ -x /usr/local/bin/rtctl-agent ]; }
}

resolve_scope() {
    _rt_owner=$(sed -n '2s/^# rtctl user uid: //p' /usr/local/bin/rt 2>/dev/null || :)
    if [ "$RT_EUID" = 0 ]; then _rt_login=${SUDO_UID:-0}; else _rt_login=$RT_UID; fi
    case "$_rt_login" in ''|*[!0-9]*) die "$EX_USAGE" '无法识别发起 sudo 的账号' ;; esac
    if [ -n "$_rt_owner" ] && [ "$_rt_owner" != "$_rt_login" ]; then
        [ "$RT_EUID" = 0 ] || die "$EX_CONFLICT" "rt 实例属于 UID $_rt_owner，请由该账号或管理员操作"
        _rt_login=$_rt_owner
    fi
    case "$_rt_login" in ''|*[!0-9]*) die "$EX_CONFLICT" '无效的 rt 实例账号' ;; esac
    if legacy_system_installed; then
        _rt_account_home=$(getent passwd "$_rt_login" | cut -d: -f6)
        if [ "$RT_SCOPE" = user ] || { [ -z "$RT_SCOPE" ] && [ -f "$_rt_account_home/.local/state/rtctl/install.env" ]; }; then
            case "$RT_SCOPE:$RT_CMD" in
                user:uninstall|user:stop|user:disable|user:config|user:status|user:version) : ;;
                *) die "$EX_CONFLICT" '发现旧系统服务。请选择要保留的实例，使用 --scope system 或 --scope user 卸载另一份后重试。' ;;
            esac
        else
            RT_SCOPE=system
        fi
    elif [ "$RT_SCOPE" = system ] && [ "$RT_CMD" != uninstall ]; then
        die "$EX_CONFLICT" '新安装使用用户服务，请去掉 --scope system'
    fi
    RT_SCOPE=${RT_SCOPE:-user}
    if [ "$RT_SCOPE" = user ] && [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$RT_UID" ]; then
        XDG_RUNTIME_DIR=/run/user/$RT_UID
        export XDG_RUNTIME_DIR
    fi
    if [ "$RT_SCOPE" = user ] && [ "$RT_EUID" = 0 ] && [ "$_rt_login" != 0 ]; then
        _rt_login_home=$(getent passwd "$_rt_login" | cut -d: -f6)
        [ -n "$_rt_login_home" ] || die "$EX_FAIL" '找不到实例所属账号'
        _rt_script=$(readlink -f "$0") || die "$EX_USAGE" '请先下载引导脚本，再运行安装'
        set -- env "HOME=$_rt_login_home" "XDG_RUNTIME_DIR=/run/user/$_rt_login" /bin/sh "$_rt_script" "$@" --scope user
        if have runuser; then exec runuser -u "$(id -nu "$_rt_login")" -- "$@"; fi
        exec sudo -H -u "#$_rt_login" -- "$@"
    fi
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
        RT_SVC_LOG=$RT_SYSTEM_AGENT_LOG
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
    RT_RELEASE_CHANNEL=''
    RT_PINNED=''
    RT_NO_FIREWALL=0
    RT_ALLOW_FROM=''
    RT_HELP=0
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
    parse_args "$@"
    if [ "$RT_CMD" = help ]; then
        cmd_help "$RT_SUB"
        return
    fi
    if [ "$RT_HELP" = 1 ]; then
        cmd_help "$RT_CMD"
        return
    fi
    if [ -z "$RT_CMD" ] && [ "${0##*/}" = "$RT_NAME" ]; then
        RT_CMD=menu
    fi
    rt_open_tty
    if [ -z "$RT_CMD" ]; then
        RT_CMD='install'
    fi
    resolve_scope "$@"
    scope_paths
    if [ "$RT_SCOPE" = system ] && [ "$RT_EUID" != 0 ]; then
        if [ -x /usr/local/bin/rt ] && [ -z "$RT_PREFIX" ] && [ "$RT_CMD" != install ] && [ "$RT_CMD" != upgrade ]; then
            if [ "$#" = 0 ]; then set -- menu; fi
            as_root /usr/local/bin/rt "$@" --scope system
            return $?
        fi
        die "$EX_NOROOT" '维护旧系统服务请用 sudo 再执行同一命令'
    fi
    if [ -n "$RT_RELEASE_CHANNEL" ]; then
        [ -z "$RT_RELEASE" ] || die "$EX_USAGE" '--dev 或 --stable 不能与 --release 同时使用'
        case "$RT_CMD" in
            install|upgrade) : ;;
            *) die "$EX_USAGE" '--dev 和 --stable 仅用于 install 或 upgrade' ;;
        esac
    fi
    if [ "$RT_CMD" != menu ] && [ "$RT_SCOPE" = system ] && [ "$RT_EUID" = 0 ]; then
        priv mkdir -p "$RT_LOG_DIR" 2>/dev/null || true
        priv chmod 0750 "$RT_LOG_DIR" 2>/dev/null || true
        priv chown root:root "$RT_LOG_DIR" 2>/dev/null || true
    fi
    rt_dispatch "$RT_CMD" "$@"
    exit $?
}

main "$@"
# RTCTL_SCRIPT_END
