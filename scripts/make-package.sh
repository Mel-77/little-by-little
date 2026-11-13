#!/bin/bash
# 打两个能发给别人的包：
#   pkg/Little by Little X.Y.zip   （zip，解压后拖进应用程序）
#   pkg/Little by Little X.Y.dmg   （推荐：双击挂载后直接拖，不会遇到"识别可写的临时文件夹出错"）
# 用法：./scripts/make-package.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
NAME="Little by Little"
STAGE="$ROOT/pkg/stage"
ZIP="$ROOT/pkg/$NAME $VER.zip"
DMG="$ROOT/pkg/$NAME $VER.dmg"
README="$ROOT/pkg/第一次打开看这里.txt"

echo "==> 构建 $VER"
./build.sh >/dev/null

echo "==> 组装"
rm -rf "$STAGE" "$ZIP" "$DMG"
mkdir -p "$STAGE/$NAME"
ditto --rsrc --extattr "$ROOT/build/$NAME.app" "$STAGE/$NAME/$NAME.app"
ln -s /Applications "$STAGE/$NAME/应用程序"

# 把窗口版式写进 .DS_Store，别人打开时就是排好的两列
osascript >/dev/null 2>&1 <<AS || true
tell application "Finder"
  activate
  open POSIX file "$STAGE/$NAME"
  delay 1
  set w to front window
  set bounds of w to {300, 200, 940, 470}
  set arrangement of icon view options of w to not arranged
  set icon size of icon view options of w to 64
  set position of item "$NAME.app" of w to {140, 62}
  set position of item "应用程序" of w to {440, 62}
  delay 0.4
  close w
end tell
AS

echo "==> 制作 dmg"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE/$NAME" -fs HFS+ -format UDZO -ov "$DMG"

echo "==> 自检"
codesign --verify --deep --strict "$STAGE/$NAME/$NAME.app" && echo "    签名完整"
lipo -info "$STAGE/$NAME/$NAME.app/Contents/MacOS/LittleByLittle" | sed 's/^/    /'
lipo -info "$STAGE/$NAME/$NAME.app/Contents/PlugIns/LittleByLittleWidget.appex/Contents/MacOS/LittleByLittleWidget" 2>/dev/null | sed 's/^/    /'
rm -rf "$STAGE"

echo "==> 好了"
echo "    $DMG  ($(du -h "$DMG" | cut -f1))"
