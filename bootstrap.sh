#!/bin/sh
set -eu
umask 077

usage() {
    printf '%s\n' '用法  sh bootstrap.sh [--stable|--dev] [install|upgrade] [选项]' >&2
}

channel=''
case "${1:-}" in
    --stable|--dev) channel=${1#--}; shift ;;
esac
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

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 15 --max-time 60 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$2" "$1"
    else
        printf '%s\n' 'curl or wget is required.' >&2
        return 1
    fi
}

work_dir=$(mktemp -d)
trap 'rm -f "$work_dir/releases.json" "$work_dir/SHA256SUMS.txt" "$work_dir/install.sh"; rmdir "$work_dir"' 0
trap 'exit 1' HUP INT TERM
if [ "$channel" = dev ]; then
    download 'https://api.github.com/repos/GotKiCry/rtctl/releases?per_page=100' "$work_dir/releases.json"
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

download "$base/SHA256SUMS.txt" "$work_dir/SHA256SUMS.txt"
download "$base/install.sh" "$work_dir/install.sh"
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
if [ "$channel" = stable ]; then
    tag=$(sed -n "s/^RT_VERSION='\([^']*\)'$/\1/p" "$work_dir/install.sh" | head -n1)
    if ! printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        printf '%s\n' 'The stable installer has an invalid version.' >&2
        exit 4
    fi
fi

sh "$work_dir/install.sh" "$@" --release "$tag"
