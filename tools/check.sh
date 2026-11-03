#!/bin/bash
# 本地语法检查 + 打包（不编译 dylib —— 那必须走 Actions/macOS 签名）
# 用法: bash tools/check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK=/root/sdks/iPhoneOS16.5.sdk
TARGET=arm64-apple-ios16.5

echo "== 语法检查"
clang -fsyntax-only -fobjc-arc -target $TARGET -isysroot "$SDK" \
  "$ROOT/client/LVDock.m"
clang -fsyntax-only -fobjc-arc -target $TARGET -isysroot "$SDK" \
  -x objective-c-header "$ROOT/client/LVGlassFilter.h"

echo "== 打包 deb（占位 dylib，真机安装需 Actions 构建）"
if [ "${1:-}" = "--package" ]; then
  STAGE=$(mktemp -d)
  mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
  cp "$ROOT/control" "$STAGE/DEBIAN/control"
  printf '#!/bin/sh\nexit 0\n' > "$STAGE/DEBIAN/postinst"; chmod 755 "$STAGE/DEBIAN/postinst"
  cp "$ROOT/client/LVGlassDock.plist" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
  echo "注意：dylib 未构建，这只是包结构预览 → $STAGE"
fi
echo OK
