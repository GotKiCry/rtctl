#!/bin/sh
# build.sh —— Linux/macOS 侧构建（等价 build.ps1）
# 产出 bin/ 下 6 个二进制 + install.sh + SHA256SUMS.txt（LF 行尾）
# 用法：sh ./build.sh [版本号]     版本缺省取 git describe
set -eu
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION=$(git describe --tags --always --dirty 2>/dev/null || printf 'v0.0.0-dev')
fi
printf '版本: %s\n' "$VERSION"

mkdir -p bin
export CGO_ENABLED=0
LD="-s -w -X rtctl/internal/agent.Version=$VERSION -X main.version=$VERSION"

for target in windows/amd64 linux/amd64 linux/arm64; do
  os=${target%%/*}
  arch=${target##*/}
  if [ "$os" = windows ]; then
    suffix=""; ext=".exe"
  else
    suffix="-${os}-${arch}"; ext=""
  fi
  GOOS=$os GOARCH=$arch go build -trimpath -ldflags "$LD" -o "bin/rtctl${suffix}${ext}" ./cmd/client
  GOOS=$os GOARCH=$arch go build -trimpath -ldflags "$LD" -o "bin/rtctl-agent${suffix}${ext}" ./cmd/agent
  printf 'built: rtctl%s%s / rtctl-agent%s%s (%s/%s)\n' "$suffix" "$ext" "$suffix" "$ext" "$os" "$arch"
done

# install.sh：注入版本号、强制 LF（Release 资产之一，也是 README 一行自举的目标）
if [ ! -f install.sh ]; then
  printf '缺少 install.sh（应在仓库根）\n' >&2
  exit 1
fi
sed "s/@@RTCTL_VERSION@@/$VERSION/g" install.sh | tr -d '\r' > bin/install.sh
chmod 0644 bin/install.sh
if grep -q '@@' bin/install.sh; then
  printf 'install.sh 仍有未替换的 @@ 占位符\n' >&2
  exit 1
fi
printf 'built: install.sh (%s)\n' "$VERSION"

# SHA256SUMS.txt：LF 行尾、纯文件名（兼容安装器的 awk 精确匹配）
cd bin
rm -f SHA256SUMS.txt
if command -v sha256sum >/dev/null 2>&1; then
  HASHER="sha256sum"
else
  HASHER="shasum -a 256"
fi
for f in $(ls -1 | grep -v '^SHA256SUMS.txt$' | sort); do
  # Windows Git Bash 会输出 *filename，统一成两个空格分隔的文本格式。
  # shellcheck disable=SC2086
  $HASHER "$f" | sed 's/^\([[:xdigit:]]\{64\}\) \*/\1  /'
done > SHA256SUMS.txt
if grep -q "$(printf '\r')" SHA256SUMS.txt; then
  printf 'SHA256SUMS.txt 含 CR，必须是 LF\n' >&2
  exit 1
fi
printf 'SHA256SUMS.txt written (%s entries, LF)\n' "$(wc -l < SHA256SUMS.txt | tr -d ' ')"
printf '提示：发布前核对 install.sh 的 sha256，并更新 CHANGELOG 与 Release 说明\n'
