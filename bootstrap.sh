#!/bin/sh
set -eu
umask 077

usage() {
    printf '%s\n' '用法  sh bootstrap.sh [--stable|--dev] [--github-prefix URL] [install|upgrade] [选项]' >&2
}

channel=''
tag=''
github_prefix=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --stable|--dev) channel=${1#--}; shift ;;
        --github-prefix)
            github_prefix=${2:-}
            case "$github_prefix" in
                *'@'*|*'?'*|*'#'*|*[[:space:]]*) usage; exit 2 ;;
                https://[[:alnum:]]*) github_prefix=${github_prefix%/} ;;
                *) usage; exit 2 ;;
            esac
            shift 2 ;;
        *) break ;;
    esac
done
if [ -z "$channel" ]; then
    if ! (test -t 1 && true </dev/tty) 2>/dev/null; then
        usage
        exit 2
    fi
    while [ -z "$channel" ]; do
        printf '%s\n' '选择安装渠道' '  1  Release（稳定版）' '  2  Dev（测试版）' '  0  退出' >&2
        printf '请选择：' >&2
        IFS= read -r answer </dev/tty || exit 0
        case "$answer" in
            1|stable|release) channel=stable ;;
            2|dev) channel=dev ;;
            0|q|exit) exit 0 ;;
            *) printf '%s\n' '请输入 1、2 或 0' >&2 ;;
        esac
    done
fi
if [ "$#" -eq 0 ]; then set -- install; fi
case "$1" in
    install) : ;;
    upgrade) set -- "$@" --detached ;;
    *) usage; exit 2 ;;
esac

# Read download options without consuming the arguments forwarded to the installer.
proxy=''
quiet=0
check_only=0
pinned_tag=''
scope=''
expect=''
for arg do
    case "$expect" in
        proxy) proxy=$arg; expect=''; continue ;;
        release) pinned_tag=$arg; expect=''; continue ;;
        scope) scope=$arg; expect=''; continue ;;
    esac
    case "$arg" in
        --proxy) expect=proxy ;;
        --proxy=*) proxy=${arg#*=} ;;
        --release) expect=release ;;
        --release=*) pinned_tag=${arg#*=} ;;
        --scope) expect=scope ;;
        --scope=*) scope=${arg#*=} ;;
        --quiet|-q) quiet=1 ;;
        --check) check_only=1 ;;
    esac
done
[ -z "$expect" ] || { usage; exit 2; }
case "$scope" in ''|system|user) : ;; *) usage; exit 2 ;; esac

# Resolve the account before running even an older Release installer.
uid=$(id -u)
owner=$uid
if [ "$uid" = 0 ]; then owner=${SUDO_UID:-0}; fi
case "$owner" in ''|*[!0-9]*) usage; exit 2 ;; esac
entry=/usr/local/bin/rt
registered=$(sed -n '2s/^# rtctl user uid: //p' "$entry" 2>/dev/null || :)
if [ -n "$registered" ]; then
    case "$registered" in *[!0-9]*) exit 8 ;; esac
    if [ "$uid" != 0 ] && [ "$registered" != "$uid" ]; then
        printf '本机 rt 实例属于 UID %s，请由该账号或管理员操作。\n' "$registered" >&2
        exit 8
    fi
    owner=$registered
elif [ "$uid" = 0 ]; then
    # Legacy installations have no public launcher. Discover existing owners before choosing one.
    owners=$(getent passwd | while IFS=: read -r _ _ candidate _ _ dir _; do
        if [ -f "$dir/.local/state/rtctl/install.env" ]; then printf '%s\n' "$candidate"; fi
    done | sort -u)
    case "$owners" in
        *'
'*) printf '%s\n' '检测到多个旧用户实例，请先保留其中一个再重试。' >&2; exit 8 ;;
        '') : ;;
        *) owner=$owners ;;
    esac
fi
owner_name=$(id -nu "$owner") || exit 8
owner_home=$(getent passwd "$owner" | cut -d: -f6)
[ -n "$owner_home" ] || exit 8
system_install=0
if [ -f /etc/rtctl/install.env ] || [ -f /etc/systemd/system/rtctl-agent.service ] ||
   [ -f /etc/init.d/rtctl-agent ] || { [ -d /etc/rtctl ] && [ -x /usr/local/bin/rtctl-agent ]; }; then
    system_install=1
fi
if [ "$system_install" = 1 ]; then
    if [ "$scope" = user ] || [ -f "$owner_home/.local/state/rtctl/install.env" ]; then
        printf '%s\n' '检测到旧系统服务。保留用户服务时，请先用旧系统管理脚本卸载 system 实例，再运行引导脚本。' >&2
        exit 8
    fi
    scope=system
    [ "$uid" = 0 ] || { printf '%s\n' '维护已有系统服务请用 sudo 运行引导脚本。' >&2; exit 6; }
elif [ "$scope" = system ]; then
    printf '%s\n' '新安装使用用户服务，请去掉 --scope system。' >&2
    exit 8
else
    scope=user
fi

download() (
    url="${github_prefix:+$github_prefix/}$1"
    dest=$2
    label=$3
    if [ "$quiet" = 0 ]; then printf '下载%s  %s\n' "$label" "$url" >&2; fi
    if [ -n "$proxy" ]; then
        https_proxy=$proxy http_proxy=$proxy
        export https_proxy http_proxy
    fi
    if command -v curl >/dev/null 2>&1; then
        set -- curl -fSL --retry 2 --connect-timeout 15 --max-time 60 -o "$dest"
        if [ -n "$proxy" ]; then set -- "$@" -x "$proxy"; fi
        if [ "$quiet" = 0 ] && [ -t 2 ]; then set -- "$@" --progress-bar; else set -- "$@" -s; fi
    elif command -v wget >/dev/null 2>&1; then
        set -- wget -T 30 -O "$dest"
        if [ "$quiet" = 1 ] || [ ! -t 2 ]; then set -- "$@" -q; fi
    else
        printf '%s\n' 'curl or wget is required.' >&2
        return 1
    fi
    if "$@" "$url"; then
        if [ "$quiet" = 0 ]; then printf '已下载%s（%s 字节）\n' "$label" "$(wc -c <"$dest")" >&2; fi
    else
        rc=$?
        printf '下载%s失败（%s 退出码 %s）  %s\n' "$label" "$1" "$rc" "$url" >&2
        if [ -n "$proxy" ]; then
            printf '%s\n' '已使用 --proxy 指定的正向代理。若节点要求拼接 GitHub 原始链接，请在 install 或 upgrade 前使用 --github-prefix URL。' >&2
        fi
        return "$rc"
    fi
)

work_dir=$(mktemp -d)
trap 'rm -f "$work_dir/releases.json" "$work_dir/SHA256SUMS.txt" "$work_dir/install.sh"; rmdir "$work_dir"' 0
trap 'exit 1' HUP INT TERM
if [ -n "$pinned_tag" ]; then
    case "$pinned_tag" in *[!0-9a-z.-]*) usage; exit 2 ;; esac
    pattern='^v[0-9]+\.[0-9]+\.[0-9]+$'
    if [ "$channel" = dev ]; then pattern='^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$'; fi
    printf '%s\n' "$pinned_tag" | grep -Eq "$pattern" || { printf '版本 %s 与所选渠道 %s 不匹配\n' "$pinned_tag" "$channel" >&2; exit 2; }
    tag=$pinned_tag
    base="https://github.com/GotKiCry/rtctl/releases/download/$tag"
elif [ "$channel" = dev ]; then
    download 'https://api.github.com/repos/GotKiCry/rtctl/releases?per_page=100' "$work_dir/releases.json" 'Dev 版本列表' || {
        printf '%s\n' '可在 install 或 upgrade 后加 --release TAG 指定已知 Dev 版本并跳过版本查询。' >&2
        exit 4
    }
    tag=$(awk -F '"' '
        $2 == "tag_name" && $4 ~ /^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$/ {
            split(substr($4, 2), version, /[.-]/)
            print version[1], version[2], version[3], version[5], $4
        }
    ' "$work_dir/releases.json" | LC_ALL=C sort -k1,1nr -k2,2nr -k3,3nr -k4,4nr | awk 'NR == 1 { print $5 }')
    if [ -z "$tag" ]; then
        printf '%s\n' 'No published rtctl dev release was found.' >&2
        exit 4
    fi
    base="https://github.com/GotKiCry/rtctl/releases/download/$tag"
else
    base='https://github.com/GotKiCry/rtctl/releases/latest/download'
fi

download "$base/SHA256SUMS.txt" "$work_dir/SHA256SUMS.txt" '校验清单'
download "$base/install.sh" "$work_dir/install.sh" '安装脚本'
expected=$(awk '$2 == "install.sh" || $2 == "*install.sh" { print $1; exit }' "$work_dir/SHA256SUMS.txt")
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$work_dir/install.sh" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$work_dir/install.sh" | awk '{ print $1 }')
elif command -v openssl >/dev/null 2>&1; then
    actual=$(openssl dgst -sha256 "$work_dir/install.sh" | awk '{ print $NF }')
else
    printf '%s\n' 'sha256sum, shasum or openssl is required.' >&2
    exit 5
fi
if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    printf '%s\n' 'SHA256 verification failed for the rtctl installer.' >&2
    exit 5
fi
installer_tag=$(sed -n "s/^RT_VERSION='\([^']*\)'$/\1/p" "$work_dir/install.sh" | head -n1)
if [ -n "${tag:-}" ] && [ "$installer_tag" != "$tag" ]; then
    printf '安装脚本版本不匹配：期望 %s，实际 %s\n' "$tag" "$installer_tag" >&2
    exit 5
fi
if [ "$channel" = stable ]; then
    tag=$installer_tag
    if ! printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        printf '%s\n' 'The stable installer has an invalid version.' >&2
        exit 4
    fi
fi

if [ -n "$github_prefix" ]; then
    cmd=$1
    shift
    set -- "$cmd" --base-url "$github_prefix/https://github.com/GotKiCry/rtctl/releases/download/$tag" "$@"
fi
if [ "$scope" = user ]; then
    # Publish only this fixed launcher. The user-owned manager is opened after dropping privileges.
    if [ -z "$registered" ] && [ "$check_only" = 0 ]; then
        if [ "$uid" = 0 ]; then set_entry() { /bin/sh -s -- "$owner"; }
        else set_entry() { sudo -- /bin/sh -s -- "$owner"; }; fi
        set_entry <<'RT_REGISTER'
        set -eu
        PATH=/usr/sbin:/usr/bin:/sbin:/bin
        export PATH
        owner=$1
        case "$owner" in ''|*[!0-9]*) exit 2 ;; esac
        getent passwd | while IFS=: read -r _ _ candidate _ _ dir _; do
            if [ "$candidate" != "$owner" ] && [ -f "$dir/.local/state/rtctl/install.env" ]; then
                printf '已有 UID %s 的 rt 服务，请使用该账号的实例。\n' "$candidate" >&2
                exit 8
            fi
        done
        entry=/usr/local/bin/rt
        if [ ! -d /usr/local/bin ]; then install -d -m 0755 /usr/local/bin; fi
        launcher=$(mktemp /usr/local/bin/.rt-user.XXXXXX)
        trap 'rm -f "$launcher"' 0
        {
            printf '#!/bin/sh\n# rtctl user uid: %s\n' "$owner"
            printf 'owner=%s\n' "$owner"
            cat <<'RT_USER_ENTRY'
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
uid=$(id -u)
if [ "$uid" != "$owner" ]; then
    [ "$uid" = 0 ] || { printf 'rt 属于 UID %s，请使用该账号或 sudo rt。\n' "$owner" >&2; exit 6; }
    account=$(id -nu "$owner")
    if command -v runuser >/dev/null; then exec runuser -u "$account" -- "$0" "$@"; fi
    exec sudo -H -u "#$owner" -- "$0" "$@"
fi
HOME=$(getent passwd "$owner" | cut -d: -f6)
: "${HOME:?无法确定实例所属账号的主目录}"
XDG_RUNTIME_DIR=/run/user/$owner
export HOME XDG_RUNTIME_DIR
state=$HOME/.local/state/rtctl/install.env
bindir=$(sed -n 's/^BIN_DIR=//p' "$state" 2>/dev/null | head -n1)
manager=${bindir:-$HOME/.local/bin}/rt
if [ ! -x "$manager" ] || [ "$manager" -ef "$0" ]; then
    printf '%s\n' '用户管理脚本缺失，请重新运行 rtctl 引导脚本。' >&2
    exit 8
fi
exec "$manager" "$@" --scope user
RT_USER_ENTRY
        } >"$launcher"
        chmod 0755 "$launcher"
        if ! ln "$launcher" "$entry" 2>/dev/null; then
            [ "$(sed -n '2s/^# rtctl user uid: //p' "$entry" 2>/dev/null)" = "$owner" ] ||
                { printf '命令路径已被占用：%s\n' "$entry" >&2; exit 8; }
        fi
RT_REGISTER
    fi
    if [ "$uid" = 0 ] && [ "$owner" != 0 ]; then
        chmod 0711 "$work_dir"
        chmod 0644 "$work_dir/install.sh"
        set -- env "HOME=$owner_home" "XDG_RUNTIME_DIR=/run/user/$owner" /bin/sh "$work_dir/install.sh" "$@" --release "$tag" --scope user
        if command -v runuser >/dev/null; then runuser -u "$owner_name" -- "$@"; else sudo -H -u "#$owner" -- "$@"; fi
        exit $?
    fi
fi
sh "$work_dir/install.sh" "$@" --release "$tag" --scope "$scope"
