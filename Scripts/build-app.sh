#!/usr/bin/env bash
# 直接用 swiftc 编译并手工组装 .app，不依赖 Xcode，也不依赖 SwiftPM。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Fxxking Work"
EXECUTABLE="Fxxking_Work"
BUNDLE_ID="dev.cailish-0425.Fxxking-Work"
# CI 发版时用 tag 覆盖，本地构建保持默认值。
VERSION="${VERSION:-1.2.4}"
DEPLOYMENT_TARGET="14.0"

# 默认输出到仓库 dist；隔离验证可用 DIST_DIR 指到别处，避免动正式产物。
DIST="${DIST_DIR:-$ROOT/dist}"
APP="$DIST/$APP_NAME.app"
BUILD="$ROOT/.build/manual"

INSTALL=0
ZIP=0
ALLOW_UNCONFIGURED=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        --allow-unconfigured-updater) ALLOW_UNCONFIGURED=1 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

SDK="$(xcrun --show-sdk-path --sdk macosx)"

# —— Sparkle SDK ——
# 优先用外部已解压目录（SPARKLE_SDK_DIR，其下有 Sparkle.framework 与 bin），
# 否则回落到 fetch-sparkle.sh 的缓存/下载。脚本 stdout 只有路径一行，进度走 stderr。
if [ -n "${SPARKLE_SDK_DIR:-}" ]; then
    if [ ! -d "$SPARKLE_SDK_DIR/Sparkle.framework" ]; then
        echo "SPARKLE_SDK_DIR 里没有 Sparkle.framework: $SPARKLE_SDK_DIR" >&2
        exit 1
    fi
    echo "==> 使用外部 Sparkle SDK: $SPARKLE_SDK_DIR"
    SDK_SPARKLE="$SPARKLE_SDK_DIR"
else
    SDK_SPARKLE="$("$ROOT/Scripts/fetch-sparkle.sh")"
fi
if [ ! -d "$SDK_SPARKLE/Sparkle.framework" ]; then
    echo "找不到 $SDK_SPARKLE/Sparkle.framework" >&2
    exit 1
fi
SPARKLE_FRAMEWORK="$SDK_SPARKLE/Sparkle.framework"

# —— 更新器配置 ——
# 公钥是**公开**配置，直接固化在脚本默认值里，这样别人 clone 源码也能直接构建；
# CI 仍可用 SPARKLE_PUBLIC_ED_KEY 覆盖（必须与签名私钥配对，否则更新包验签失败）。
SU_FEED_URL="${SU_FEED_URL:-https://github.com/cailish-0425/Fxxking_Work/releases/latest/download/appcast.xml}"
DEFAULT_SPARKLE_PUBLIC_ED_KEY="guGuN8euucnNQT73lPQK6jFCpoyMKsVBBFBwz8qZfHs="
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-$DEFAULT_SPARKLE_PUBLIC_ED_KEY}"
# 兼容旧变量名，避免已有调用脚本失效。
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-$SPARKLE_PUBLIC_ED_KEY}"

if [ "$ALLOW_UNCONFIGURED" -ne 1 ]; then
    case "$SU_FEED_URL" in
        https://*) ;;
        *) echo "SUFeedURL 必须是 HTTPS: $SU_FEED_URL" >&2; exit 1 ;;
    esac
    if [ -z "$SU_PUBLIC_ED_KEY" ]; then
        echo "缺少 SPARKLE_PUBLIC_ED_KEY（Sparkle 公钥）" >&2
        exit 1
    fi
    # 必须是 base64 的 32 字节 Ed25519 公钥；解码长度不对直接失败，
    # 否则会产出一个「看起来有更新器、实际永远验签失败」的半残包。
    decoded_len="$(printf '%s' "$SU_PUBLIC_ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
    if [ "$decoded_len" != "32" ]; then
        echo "SPARKLE_PUBLIC_ED_KEY 不是合法的 32 字节 base64 Ed25519 公钥（解码得到 ${decoded_len:-0} 字节）" >&2
        exit 1
    fi
else
    echo "    （--allow-unconfigured-updater 已启用：本次产物不含更新器配置）"
    SU_PUBLIC_ED_KEY=""
fi

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
        -F "$SDK_SPARKLE" \
        -framework Sparkle \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
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

# Sparkle framework 整个拷进去。必须用 ditto：它保留 Versions/Current 这类符号链接
# 和 Updater.app / Autoupdate / XPCServices 这些内嵌 helper，cp -R 会破坏结构。
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
echo "==> 嵌入 Sparkle.framework ($(lipo -archs "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" 2>/dev/null || echo '?'))"

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

# 更新器配置：只有拿到真实公钥才写进 Info.plist。
UPDATER_PLIST_ENTRIES=""
if [ -n "$SU_PUBLIC_ED_KEY" ]; then
    UPDATER_PLIST_ENTRIES="    <key>SUFeedURL</key><string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SU_PUBLIC_ED_KEY</string>
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>"
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
${UPDATER_PLIST_ENTRIES}
</dict>
</plist>
PLIST

# 先重签 framework 里会被系统单独校验的组件，再签 app 本体。
# Sparkle 的 Updater.app / Autoupdate / XPC 服务各自需要有效签名，外层签名不会自动覆盖它们。
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    for helper in \
        "$FW/Versions/B/Autoupdate" \
        "$FW/Versions/B/Updater.app" \
        "$FW/Versions/B/XPCServices/Downloader.xpc" \
        "$FW/Versions/B/XPCServices/Installer.xpc"; do
        [ -e "$helper" ] || continue
        codesign --force --deep --preserve-metadata=identifier,entitlements --sign - "$helper" >/dev/null
    done
    codesign --force --sign - "$FW" >/dev/null
fi
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "==> 完成: ${APP} (架构: ${BUILT_ARCHS[*]})"

if [ "$ZIP" -eq 1 ]; then
    ARCHIVE="$DIST/$APP_NAME.zip"
    rm -f "$ARCHIVE"
    # 必须用 ditto 而不是 zip：后者不保留 macOS 的元数据，签名会在解压后失效。
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    echo "==> 压缩包: ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1))"
    echo "    首次运行请按 macOS 安全提示处理；当前包未做 Apple 公证。"
fi

if [ "$INSTALL" -eq 1 ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> 安装到 $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
fi
