#!/bin/bash
# 构建 Little by Little.app（ObjC + WKWebView，无需 Xcode）
# 用法：./build.sh            生成 build/Little by Little.app
#       ./build.sh --run      构建后直接打开
#       ./build.sh --install  构建后装到 /Applications（启动台可见）并打开
#       ./build.sh --install --run  同上
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Little by Little.app"
BIN="$APP/Contents/MacOS/LittleByLittle"
BUNDLE_ID="com.littlebylittle.app"
SIGN_IDENTITY="${LBL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development:/{print $2; exit}')}"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "需要有效 Apple Development 签名证书才能构建交互小组件。" >&2
  exit 1
fi

SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" "$ROOT/.cache"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 编译"
# 保存后立刻刷新桌面小组件用的 Swift 桥（WidgetCenter 只有 Swift API）
SWIFT_OBJ="$ROOT/.cache/WidgetReload.o"
rm -f "$SWIFT_OBJ"
if command -v swiftc >/dev/null 2>&1; then
  mkdir -p "$ROOT/.cache/arm64" "$ROOT/.cache/x86_64"
  for arch in arm64 x86_64; do
    swiftc -c -O -parse-as-library -target "$arch-apple-macos14.0" -sdk "$SDK" \
      "$ROOT/Sources/WidgetReload.swift" -o "$ROOT/.cache/$arch/WidgetReload.o" 2>"$ROOT/.cache/reload-$arch.log" || true
  done
  if [ -f "$ROOT/.cache/arm64/WidgetReload.o" ] && [ -f "$ROOT/.cache/x86_64/WidgetReload.o" ]; then
    lipo -create "$ROOT/.cache/arm64/WidgetReload.o" "$ROOT/.cache/x86_64/WidgetReload.o" -output "$SWIFT_OBJ"
  elif [ -f "$ROOT/.cache/arm64/WidgetReload.o" ]; then
    cp "$ROOT/.cache/arm64/WidgetReload.o" "$SWIFT_OBJ"
  else
    echo "    ⚠︎ 小组件即时刷新不可用（swiftc 失败，见 .cache/reload-*.log）"; rm -f "$SWIFT_OBJ"
  fi
fi
EXTRA=()
if [ -f "$SWIFT_OBJ" ]; then
  EXTRA=("$SWIFT_OBJ" -framework WidgetKit -L/usr/lib/swift -lswiftCore -Wl,-rpath,/usr/lib/swift)
fi
clang -fobjc-arc -O1 -g \
  -arch arm64 -arch x86_64 \
  -isysroot "$SDK" \
  -mmacosx-version-min=14.0 \
  -framework Cocoa -framework WebKit -framework Carbon \
  -o "$BIN" \
  "$ROOT/Sources/main.m" \
  "$ROOT/Sources/AppDelegate.m" \
  "$ROOT/Sources/Store.m" \
  ${EXTRA[@]+"${EXTRA[@]}"}

echo "==> 拷贝界面"
cp "$ROOT/Resources/"*.html "$ROOT/Resources/"*.css "$ROOT/Resources/"*.js \
   "$APP/Contents/Resources/web/"

echo "==> 图标"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> 小组件（WidgetKit 扩展，swiftc 直编）"
if [ -f "$ROOT/SourcesWidget/LittleByLittleWidget.swift" ] && command -v swiftc >/dev/null 2>&1; then
  WIDGET="$APP/Contents/PlugIns/LittleByLittleWidget.appex"
  mkdir -p "$WIDGET/Contents/MacOS"
  WOK=1
  printf '%s\n' '["AppIntent","AppEntity","AppEnum","AppShortcutsProvider"]' > "$ROOT/.cache/intent-protocols.json"
  printf '%s\n' "$ROOT/SourcesWidget/LittleByLittleWidget.swift" > "$ROOT/.cache/intent-sources"
  printf '%s\n' "$ROOT/.cache/arm64/widget.swiftconstvalues" > "$ROOT/.cache/intent-const-values"
  for arch in arm64 x86_64; do
    mkdir -p "$ROOT/.cache/$arch"
    swiftc -O -parse-as-library -target "$arch-apple-macos14.0" -sdk "$SDK" \
      -module-name LittleByLittleWidget \
      -const-gather-protocols-list "$ROOT/.cache/intent-protocols.json" \
      -emit-const-values-path "$ROOT/.cache/$arch/widget.swiftconstvalues" \
      -framework SwiftUI -framework WidgetKit \
      -Xlinker -e -Xlinker _NSExtensionMain \
      -o "$ROOT/.cache/$arch/LittleByLittleWidget" \
      "$ROOT/SourcesWidget/LittleByLittleWidget.swift" 2>"$ROOT/.cache/widget-$arch.log" || WOK=0
  done
  if [ "$WOK" = "1" ] && lipo -create "$ROOT/.cache/arm64/LittleByLittleWidget" "$ROOT/.cache/x86_64/LittleByLittleWidget" \
      -output "$WIDGET/Contents/MacOS/LittleByLittleWidget"; then
    cp "$ROOT/SourcesWidget/Info.plist" "$WIDGET/Contents/Info.plist"
    # Interactive buttons require the App Intents index in addition to swiftc output.
    PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
    if [ -n "$PROCESSOR" ]; then
      mkdir -p "$WIDGET/Contents/Resources"
      swiftc -emit-object -parse-as-library -module-name LittleByLittleWidget \
        -target arm64-apple-macos14.0 -sdk "$SDK" \
        -const-gather-protocols-list "$ROOT/.cache/intent-protocols.json" \
        -emit-const-values-path "$ROOT/.cache/arm64/widget.swiftconstvalues" \
        "$ROOT/SourcesWidget/LittleByLittleWidget.swift" -o "$ROOT/.cache/arm64/widget-metadata.o"
      "$PROCESSOR" --module-name LittleByLittleWidget \
        --output "$WIDGET/Contents/Resources" \
        --sdk-root "$SDK" --target-triple arm64-apple-macos14.0 \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
        --platform-family macOS --deployment-target 14.0 \
        --source-file-list "$ROOT/.cache/intent-sources" \
        --swift-const-vals-list "$ROOT/.cache/intent-const-values"
    else
      echo "缺少 App Intents 元数据工具，停止构建交互小组件。" >&2
      exit 1
    fi
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --identifier "com.littlebylittle.app.widget" \
      --entitlements "$ROOT/SourcesWidget/widget.entitlements" "$WIDGET"
    echo "    已内置桌面小组件"
  else
    echo "    小组件编译失败"
    head -20 "$ROOT/.cache/widget-arm64.log" || true
    exit 1
  fi
fi

echo "==> 签名"
# Remove local debug symbols from the deliverable before signing.
rm -rf "$APP/Contents/MacOS/LittleByLittle.dSYM"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --identifier "$BUNDLE_ID" --entitlements "$ROOT/Sources/app.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 完成: $APP"

install_app() {
  echo "==> 安装到 /Applications"
  pkill -f "/Applications/Little by Little.app/Contents/MacOS/LittleByLittle" 2>/dev/null || true
  rm -rf "/Applications/Little by Little.app"
  cp -R "$APP" "/Applications/Little by Little.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/Little by Little.app" 2>/dev/null || true
  if [ -d "/Applications/Little by Little.app/Contents/PlugIns" ]; then
    pluginkit -a "/Applications/Little by Little.app/Contents/PlugIns/LittleByLittleWidget.appex" 2>/dev/null || true
    killall chronod 2>/dev/null || true
  fi
  echo "==> 已安装: /Applications/Little by Little.app（启动台里能看到）"
}

for arg in "$@"; do
  case "$arg" in
    --install) install_app ;;
    --run) open "$APP" ;;
  esac
done
