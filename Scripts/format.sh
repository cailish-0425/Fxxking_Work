#!/usr/bin/env bash
# 按 .swift-format 的规则整理代码；加 --check 只报告不改动。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGETS=("$ROOT/Sources" "$ROOT/Checks")

if ! command -v swift-format >/dev/null 2>&1; then
    echo "找不到 swift-format，用 brew install swift-format 安装" >&2
    exit 1
fi

if [ "${1:-}" = "--check" ]; then
    swift-format lint --recursive "${TARGETS[@]}"
    echo "格式检查通过"
else
    swift-format format --in-place --recursive "${TARGETS[@]}"
    echo "已格式化"
fi
