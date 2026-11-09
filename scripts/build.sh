#!/bin/bash
# 构建 SimpleShot.app
#   ./scripts/build.sh            构建到 build/SimpleShot.app
#   ./scripts/build.sh --install  构建并安装到 /Applications
#   ./scripts/build.sh --dmg      构建并打包成 build/SimpleShot.dmg
#
# 签名：默认使用临时签名（ad-hoc）。临时签名每次构建都会变，macOS 可能要求重新授予
# “屏幕录制”权限。想避免这一点，可在“钥匙串访问”里创建一个自签名的“代码签名”证书，
# 然后：SIGN_IDENTITY="证书名称" ./scripts/build.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SimpleShot"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# UNIVERSAL=1 时同时编译 Apple Silicon 与 Intel（需要完整 Xcode）
BUILD_ARGS=(-c release)
if [ "${UNIVERSAL:-0}" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> 编译 (release)"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "==> 打包 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

echo "==> 签名 (${SIGN_IDENTITY})"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"

if [ "${1:-}" = "--dmg" ]; then
    echo "==> 制作 DMG"
    DMG="build/${APP_NAME}.dmg"
    STAGE="build/dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
    echo "完成：$DMG"
elif [ "${1:-}" = "--install" ]; then
    echo "==> 安装到 /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "已安装并启动：/Applications/${APP_NAME}.app"
else
    echo "完成：$APP"
    echo "运行：open $APP"
fi
