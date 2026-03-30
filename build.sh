#!/bin/bash
set -e

# ══════════════════════════════════════════
#  配置区 — 按需修改
# ══════════════════════════════════════════
APP_NAME="Numaric"
BUNDLE_ID="com.2O48.numaric"
ICON_SRC="AppIcon.icns"          # ← 你的 icns 文件名（区分大小写）
SWIFT_SRC="main.swift"           # ← 你的 Swift 源文件

# ══════════════════════════════════════════
#  路径定义（无需修改）
# ══════════════════════════════════════════
APP="${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

# ══════════════════════════════════════════
#  1. 清理旧构建
# ══════════════════════════════════════════
echo "▶ 清理旧构建..."
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

# ══════════════════════════════════════════
#  2. 编译（同时将 Info.plist 嵌入二进制）
# ══════════════════════════════════════════
echo "▶ 编译 $SWIFT_SRC ..."
swiftc "$SWIFT_SRC" \
  -framework Carbon \
  -framework Cocoa \
  -O \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker Info.plist \
  -o "$MACOS/$APP_NAME"

# ══════════════════════════════════════════
#  3. 写入 Info.plist 文件（双保险）
# ══════════════════════════════════════════
echo "▶ 写入 Info.plist..."
cp Info.plist "$CONTENTS/Info.plist"

# ══════════════════════════════════════════
#  4. 拷贝图标
# ══════════════════════════════════════════
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$RESOURCES/$ICON_SRC"
  echo "✅ 图标已写入 Resources/$ICON_SRC"
else
  echo "⚠️  未找到 $ICON_SRC，跳过图标"
fi

# ══════════════════════════════════════════
# ── 5. 移除扩展属性（必须在签名前执行）──
# ══════════════════════════════════════════
echo "▶ 清理扩展属性..."
xattr -cr "$APP"

# ══════════════════════════════════════════
# ── 6. Ad-hoc 代码签名 ──
# ══════════════════════════════════════════
echo "▶ 签名..."
codesign --force --deep --sign - "$APP"
echo "✅ 签名完成"

# ══════════════════════════════════════════
#  7. 重置辅助功能权限（每次重新编译必须执行）
# ══════════════════════════════════════════
echo "▶ 重置辅助功能权限..."
tccutil reset Accessibility "$BUNDLE_ID"
echo "✅ 权限已重置，首次运行时请重新授权"

# ══════════════════════════════════════════
#  8. 刷新图标缓存
# ══════════════════════════════════════════
echo "▶ 刷新图标缓存..."
killall Finder 2>/dev/null || true
killall Dock   2>/dev/null || true

cp -R "$APP" /Applications/
echo "✅ 已安装到 /Applications"

echo ""
echo "✅ 构建完成：$APP"
echo ""
echo "  后续步骤："
echo "  1. 运行 App：open $APP"
echo "  2. 系统设置 → 隐私与安全性 → 辅助功能 → 手动添加 $APP"