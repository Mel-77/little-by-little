#!/bin/bash
# 把 SourcesWidget/LittleByLittleWidget.swift 里的视图部分抽出来，离屏渲染一张大号小组件 PNG。
# 用法: ./scripts/make-widget-preview.sh [out.png] [w] [h]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.test/widget-large.png}"
W="${2:-338}"
H="${3:-338}"
SDK="$(xcrun --show-sdk-path)"
SRC="$ROOT/SourcesWidget/LittleByLittleWidget.swift"
TMP="$ROOT/.test/widget_preview.swift"

python3 - "$SRC" "$TMP" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
head = s.split("// MARK: - Widget")[0].rstrip("\n")
# 预览不经过 WidgetKit 宿主，family 得写死（\.widgetFamily 是只读 KeyPath，注入不进去）
head = head.replace('@Environment(\\.widgetFamily) private var family',
                    'private var family: WidgetFamily { .systemLarge }')
if head.splitlines()[-1].strip() != "}":
    head += "\n}"
main = '''

// MARK: - 离屏预览（测试用，不进 appex）

@main
struct WidgetPreview {
    static func main() {
        let args = CommandLine.arguments
        let out = args.count > 1 ? args[1] : "widget-preview.png"
        let w = args.count > 2 ? (Double(args[2]) ?? 338) : 338
        let h = args.count > 3 ? (Double(args[3]) ?? 338) : 338
        let ref = Date()
        let entry = LittleByLittleEntry(date: ref, snap: StoreReader.snapshot(for: ref))
        let view = LittleByLittleWidgetView(entry: entry)
            .frame(width: w, height: h)
            .background(Color(red: 0.984, green: 0.965, blue: 0.922))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed"); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: out))
        print("ok -> \\(out)")
    }
}
'''
open(dst, "w").write(head + main)
PY

swiftc -O -parse-as-library -target arm64-apple-macos14.0 -sdk "$SDK" \
  -framework SwiftUI -framework WidgetKit \
  -o "$ROOT/.test/widget_preview" "$TMP"
"$ROOT/.test/widget_preview" "$OUT" "$W" "$H"
