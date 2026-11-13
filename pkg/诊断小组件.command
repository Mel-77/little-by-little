#!/bin/bash
# Little by Little · 诊断小组件
# 双击运行。它把小组件相关的全部信息写成一个文本文件放在桌面上，发回给作者即可。
APP="/Applications/Little by Little.app"
OUT="$HOME/Desktop/Little by Little 小组件检查.txt"

{
  echo "Little by Little · 小组件诊断包"
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo
  echo "=== 系统 ==="
  sw_vers
  uname -m
  echo
  echo "=== App ==="
  if [ -d "$APP" ]; then
    echo "位置：$APP"
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null | sed 's/^/版本：/'
    echo -n "隔离属性："; xattr -p com.apple.quarantine "$APP" 2>/dev/null || echo "无"
  else
    echo "!! /Applications 里没有；下面列出可能的位置："
    find "$HOME/Applications" "$HOME/Downloads" "$HOME/Desktop" -maxdepth 3 -name "Little by Little.app" 2>/dev/null
  fi
  echo
  echo "=== 内置自检 ==="
  BIN="$APP/Contents/MacOS/LittleByLittle"
  if [ -x "$BIN" ]; then
    "$BIN" --check-widget 2>&1
  else
    echo "找不到可执行文件，跳过"
  fi
  echo
  echo "=== 系统里的全部小组件插件（截取我们的） ==="
  pluginkit -m -A -D -v -i com.littlebylittle.app.widget 2>&1
  echo
  echo "=== chronod / 通知中心 ==="
  pgrep -lx chronod || echo "chronod 没在跑"
  pgrep -lx NotificationCenter || echo "NotificationCenter 没在跑"
} > "$OUT" 2>&1

echo "已写到：$OUT"
open -e "$OUT"
