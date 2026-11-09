#!/usr/bin/env bash
# 获取并校验固定版本的 Sparkle SDK（2.10.1）。
#
# 契约：**stdout 只输出一行绝对 SDK 目录**（其下有 Sparkle.framework 与 bin），
# 所有进度/错误走 stderr。CI 里可以直接：
#
#   SPARKLE_SDK_DIR="$(./Scripts/fetch-sparkle.sh)" >> "$GITHUB_ENV"
#
# 若已设置 SPARKLE_SDK_DIR 且目录里确实有 Sparkle.framework，就直接回显该目录，不下载。
#
# - 版本写死，不查 latest；校验的是官方发行包 tar.xz 的 sha256。
# - 下载缓存放 .build/sparkle/（已被 .gitignore 覆盖），framework 二进制不入库。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
CACHE="$ROOT/.build/sparkle"
ARCHIVE="$CACHE/Sparkle-$SPARKLE_VERSION.tar.xz"
SDK_ROOT="$CACHE/$SPARKLE_VERSION"

log() { echo "==> $*" >&2; }

# 已有外部 SDK：直接用，不重复下载。
if [ -n "${SPARKLE_SDK_DIR:-}" ]; then
    if [ -d "$SPARKLE_SDK_DIR/Sparkle.framework" ]; then
        log "使用外部 SDK: $SPARKLE_SDK_DIR"
        echo "$SPARKLE_SDK_DIR"
        exit 0
    fi
    log "SPARKLE_SDK_DIR 里没有 Sparkle.framework: $SPARKLE_SDK_DIR"
    exit 1
fi

if [ -d "$SDK_ROOT/Sparkle.framework" ]; then
    log "Sparkle $SPARKLE_VERSION 已在缓存"
    echo "$SDK_ROOT"
    exit 0
fi

mkdir -p "$CACHE"

download_url() {
    echo "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
}

if [ ! -f "$ARCHIVE" ]; then
    log "下载 Sparkle $SPARKLE_VERSION"
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 "$(download_url)" -o "$ARCHIVE"
else
    log "使用已缓存的发行包: $ARCHIVE"
fi

log "校验 sha256"
actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$actual" != "$SPARKLE_SHA256" ]; then
    echo "Sparkle 发行包校验失败" >&2
    echo "  期望: $SPARKLE_SHA256" >&2
    echo "  实际: $actual" >&2
    rm -f "$ARCHIVE"
    exit 1
fi

log "解包到 $SDK_ROOT"
rm -rf "$SDK_ROOT"
mkdir -p "$SDK_ROOT"
tar -xJf "$ARCHIVE" -C "$SDK_ROOT"

if [ ! -d "$SDK_ROOT/Sparkle.framework" ]; then
    echo "解包后找不到 Sparkle.framework" >&2
    exit 1
fi

# 只留 framework 和签名/打包工具，其余（SampleApp、Symbols、文档）不占缓存。
rm -rf "$SDK_ROOT/bin/old_dsa_scripts" "$SDK_ROOT/Symbols" 2>/dev/null || true

log "就绪: $(lipo -archs "$SDK_ROOT/Sparkle.framework/Versions/B/Sparkle" 2>/dev/null || echo '?')"

# 唯一一行 stdout。
echo "$SDK_ROOT"
