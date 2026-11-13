#!/bin/bash
# Little by Little · 修小组件
# 双击运行。它会：去掉下载包的隔离标记 → 清掉指向已删除路径的旧登记 →
# 重新登记小组件 → 重启小组件服务。跑完再去「编辑小组件」里看一眼。
ID="com.littlebylittle.app.widget"
APP="/Applications/Little by Little.app"

pause() { read -n 1 -s -r -p "按任意键关闭…"; echo; }

echo "== 0. 系统 =="
echo "   $(sw_vers -productVersion)  $(uname -m)"
MAJ=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJ" -lt 14 ]; then
  echo "!! 桌面小组件要 macOS 14 以上；这台是 $(sw_vers -productVersion)，所以找不到是正常的。"
  pause; exit 1
fi

echo "== 1. 找到 App =="
if [ ! -d "$APP" ]; then
  echo "!! /Applications 里没有 Little by Little.app"
  ALT=$(find "$HOME/Applications" "$HOME/Downloads" "$HOME/Desktop" -maxdepth 3 -name "Little by Little.app" 2>/dev/null | head -1)
  if [ -n "$ALT" ]; then
    echo "   发现另一份：$ALT"
    echo "   请先把它拖进「应用程序」文件夹（或直接挪过去）再运行本脚本。"
  else
    echo "   请先把 App 拖进「应用程序」再运行本脚本。"
  fi
  pause; exit 1
fi
echo "   $APP"
APPEX="$APP/Contents/PlugIns/LittleByLittleWidget.appex"

echo "== 2. 去掉隔离标记（从网上下载的包会带） =="
xattr -dr com.apple.quarantine "$APP" 2>/dev/null && echo "   完成" || echo "   没有可清的标记"

echo "== 3. 清理失效的旧登记 =="
while IFS= read -r line; do
  [ -z "$line" ] && continue
  path=$(printf '%s' "$line" | sed -n 's|^[^/]*\(/.*\)$|\1|p')
  [ -z "$path" ] && continue
  [ "$path" = "$APPEX" ] && continue
  if [ -e "$path" ]; then
    echo "   跳过（还在）: $path"
  else
    echo "   删除失效登记: $path"
    pluginkit -r "$path" 2>/dev/null
  fi
done < <(pluginkit -m -A -D -v -i "$ID" 2>/dev/null)

echo "== 4. 重新登记 =="
pluginkit -a "$APPEX" && echo "   已登记"

echo "== 5. 重启小组件服务 =="
killall chronod 2>/dev/null && echo "   chronod 已重启" || echo "   chronod 没在跑（没关系）"
killall NotificationCenter 2>/dev/null && echo "   通知中心已重启" || true

echo
echo "== 6. 现在系统里的登记 =="
pluginkit -m -A -D -v -i "$ID" | sed 's/^/   /'

echo
echo "完成。现在在桌面右键 →「编辑小组件」，搜「Little by Little」或 little。"
echo "如果还是没有，请把 「诊断小组件.command」 生成的文件发给作者。"
pause
