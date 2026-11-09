#!/usr/bin/env bash
# 直接用 swiftc 编译并手工组装 .app，不依赖 Xcode，也不依赖 SwiftPM。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Fxxking Work"
EXECUTABLE="Fxxking_Work"
BUNDLE_ID="dev.cailish-0425.Fxxking-Work"
# CI 发版时用 tag 覆盖，本地构建保持默认值。
VERSION="${VERSION:-1.2.0}"
DEPLOYMENT_TARGET="14.0"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
BUILD="$ROOT/.build/manual"

INSTALL=0
ZIP=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)

if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "找不到任何 Swift 源文件" >&2
    exit 1
fi

rm -rf "$APP" "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile_arch() {
    local arch="$1"
    swiftc \
        -O \
        -parse-as-library \
        -swift-version 6 \
        -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
        -sdk "$SDK" \
        -o "$BUILD/$EXECUTABLE-$arch" \
        "${SOURCES[@]}"
}

HOST_ARCH="$(uname -m)"
BUILT_ARCHS=()

echo "==> 编译 $HOST_ARCH"
compile_arch "$HOST_ARCH"
BUILT_ARCHS+=("$HOST_ARCH")

OTHER_ARCH="x86_64"
[ "$HOST_ARCH" = "x86_64" ] && OTHER_ARCH="arm64"

echo "==> 编译 ${OTHER_ARCH} (失败则只保留 ${HOST_ARCH})"
if compile_arch "$OTHER_ARCH" 2>/dev/null; then
    BUILT_ARCHS+=("$OTHER_ARCH")
else
    echo "    跳过 ${OTHER_ARCH}, 产物将只支持 ${HOST_ARCH}"
fi

BINARIES=()
for arch in "${BUILT_ARCHS[@]}"; do BINARIES+=("$BUILD/$EXECUTABLE-$arch"); done
lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$EXECUTABLE"

# 本地化资源。.strings 和 .stringsdict 运行时由 CFBundle 直接读取，
# 不需要编译，所以手工组装的 bundle 也能用上完整的本地化。
LANG_CODES=()
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    LANG_CODES+=("$(basename "$lproj" .lproj)")
done

if [ ${#LANG_CODES[@]} -eq 0 ]; then
    echo "找不到任何 .lproj，界面会退化成显示 key" >&2
    exit 1
fi

echo "==> 本地化: ${LANG_CODES[*]}"

# 应用图标。仓库里只存一张 1024 母版，各尺寸和 .icns 在构建时用系统自带的
# sips 和 iconutil 生成，免得把十来个尺寸的 PNG 都塞进版本库。
ICON_SRC="$ROOT/Resources/AppIcon.png"
ICON_PLIST_ENTRY=""
if [ -f "$ICON_SRC" ]; then
    ICONSET="$BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST_ENTRY='<key>CFBundleIconFile</key><string>AppIcon</string>'
    echo "==> 图标: AppIcon.icns"
else
    echo "==> 没有 Resources/AppIcon.png, 本次不带图标"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    ${ICON_PLIST_ENTRY}
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <!-- 英文是源语言，没翻到的条目回退到它。支持哪些语言由 .lproj 目录本身决定，
         再写一遍 CFBundleLocalizations 只会让 Bundle.localizations 出现重复项。 -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 cailish-0425</string>
    <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 菜单栏应用，不在 Dock 和 Cmd-Tab 里出现 -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "    临时签名失败，应用仍可运行"

echo "==> 完成: ${APP} (架构: ${BUILT_ARCHS[*]})"

if [ "$ZIP" -eq 1 ]; then
    ARCHIVE="$DIST/$APP_NAME.zip"
    rm -f "$ARCHIVE"
    # 必须用 ditto 而不是 zip：后者不保留 macOS 的元数据，签名会在解压后失效。
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    echo "==> 压缩包: ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1))"
    echo "    对方解压后需要先去掉隔离属性: xattr -dr com.apple.quarantine \"/Applications/${APP_NAME}.app\""
fi

if [ "$INSTALL" -eq 1 ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> 安装到 $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
fi
