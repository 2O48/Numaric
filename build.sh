#!/bin/bash
set -e

APP="Numaric.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# ── 图标文件名（与你实际的 .icns 文件名一致）──
ICON_SRC="AppIcon.icns"   # ← 改成你的 icns 文件名

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

echo "▶ 编译..."
swiftc main.swift \
    -framework Carbon \
    -framework Cocoa \
    -O \
    -o "$MACOS/Numaric"

cp Info.plist "$CONTENTS/Info.plist"

# ── 拷贝图标 ──
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$RESOURCES/$ICON_SRC"
    echo "✅ 图标已写入 Resources/$ICON_SRC"
else
    echo "⚠️  未找到 $ICON_SRC，跳过图标"
fi

echo "✅ 构建完成：$APP"