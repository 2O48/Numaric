#!/bin/bash
set -e

APP="Numaric.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# 清理旧包
rm -rf "$APP"

# 创建目录结构
mkdir -p "$MACOS" "$RESOURCES"

# 编译二进制（直接输出到 MacOS/ 目录）
echo "▶ 编译..."
swiftc main.swift \
    -framework Carbon \
    -framework Cocoa \
    -O \
    -o "$MACOS/Numaric"

# 拷贝 Info.plist
cp Info.plist "$CONTENTS/Info.plist"

# 可选：如果有 AppIcon.icns，拷贝进去
# cp AppIcon.icns "$RESOURCES/AppIcon.icns"

echo "✅ 构建完成：$APP"
echo ""
echo "使用方法："
echo "  1. 把 Numaric.app 拖到 /Applications/"
echo "  2. 双击启动，授予辅助功能权限"
echo "  3. 以后重新编译只需再次运行 ./build.sh，无需重新授权"