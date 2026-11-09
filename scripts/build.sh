#!/bin/bash
# 构建 SimpleShot.app
#   ./scripts/build.sh            构建到 build/SimpleShot.app
#   ./scripts/build.sh --install  构建并安装到 /Applications
#   ./scripts/build.sh --dmg      构建并打包成 build/SimpleShot-<版本>.dmg
#
# 版本号写在仓库根目录的 VERSION 文件里。
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
# 版本号：VERSION 文件；构建号：git 提交次数
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
echo "    版本 $VERSION (build $BUILD_NUMBER)"
# 图标：从 1024×1024 母版生成
#  - Assets.car（资源目录，macOS 26+ 显示图标所需，需要完整 Xcode 的 actool）
#  - AppIcon.icns（兼容旧系统；没有 Xcode 时用 iconutil 生成）
if [ -f Resources/AppIcon.png ]; then
    ICONSET="build/AppIcon.iconset"
    XCASSETS="build/Assets.xcassets"
    APPICONSET="$XCASSETS/AppIcon.appiconset"
    rm -rf "$ICONSET" "$XCASSETS"
    mkdir -p "$ICONSET" "$APPICONSET"
    IMAGES=""
    for s in 16 32 128 256 512; do
        d=$((s * 2))
        sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
        cp "$ICONSET/icon_${s}x${s}.png" "$ICONSET/icon_${s}x${s}@2x.png" "$APPICONSET/"
        IMAGES="$IMAGES{\"idiom\":\"mac\",\"size\":\"${s}x${s}\",\"scale\":\"1x\",\"filename\":\"icon_${s}x${s}.png\"},"
        IMAGES="$IMAGES{\"idiom\":\"mac\",\"size\":\"${s}x${s}\",\"scale\":\"2x\",\"filename\":\"icon_${s}x${s}@2x.png\"},"
    done
    echo "{\"images\":[${IMAGES%,}],\"info\":{\"version\":1,\"author\":\"xcode\"}}" > "$APPICONSET/Contents.json"
    echo '{"info":{"version":1,"author":"xcode"}}' > "$XCASSETS/Contents.json"

    if xcrun --find actool >/dev/null 2>&1; then
        xcrun actool "$XCASSETS" --compile "$APP/Contents/Resources" \
            --platform macosx --minimum-deployment-target 14.0 \
            --app-icon AppIcon --output-partial-info-plist build/AssetsInfo.plist \
            --output-format human-readable-text --notices --warnings
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" >/dev/null
        echo "    已生成 Assets.car"
    else
        echo "    未找到 actool（需要完整 Xcode），仅生成 .icns"
    fi
    # actool 会顺带生成 AppIcon.icns；没有的话用 iconutil 生成
    if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    fi
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
    rm -rf "$ICONSET" "$XCASSETS" build/AssetsInfo.plist
    ls -la "$APP/Contents/Resources"
fi

echo "==> 签名 (${SIGN_IDENTITY})"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"

if [ "${1:-}" = "--dmg" ]; then
    echo "==> 制作 DMG"
    DMG="build/${APP_NAME}-${VERSION}.dmg"
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
