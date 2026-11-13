#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成两份 PDF：《安装说明》《使用说明》。
每页用 Cocoa 渲染器（.test/mkpage）画成 A4 3x PNG，再用 Pillow 合成 PDF。

    python3 scripts/make-pdf.py           # 两份都做
    python3 scripts/make-pdf.py install   # 只做安装
    python3 scripts/make-pdf.py usage     # 只做使用
"""
import json, os, re, subprocess, sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, "shots")
TMP = os.path.join(ROOT, ".test", "pages")
MKPAGE = os.path.join(ROOT, ".test", "mkpage")
VERSION = "2.7.2"


def img(name, h=0, caption=""):
    d = {"t": "img", "path": os.path.join(SHOTS, name)}
    if h:
        d["h"] = h
    if caption:
        d["caption"] = caption
    return d


def cover(title, subtitle, picture, hint):
    return {"cover": True, "title": title, "subtitle": subtitle,
            "image": {"path": os.path.join(SHOTS, picture)}, "hint": hint}


# ══════════════════════════════════════════════════════
#  安装说明
# ══════════════════════════════════════════════════════
INSTALL = [
    cover("安装", "Little by Little %s · 大约 3 分钟\n装好之后，另一份《使用说明》讲怎么用" % VERSION,
          "01-dmg.png", "双击那个 .dmg，从第 3 页开始做"),

    {"blocks": [
        {"t": "kicker", "text": "装之前"},
        {"t": "h1", "text": "四步，三分钟"},
        {"t": "bullet", "text": "系统要 macOS 14 或更高；Apple 芯片、Intel 都行。"},
        {"t": "bullet", "text": "不用 Xcode，不用联网，不用装任何运行库。"},
        {"t": "bullet", "text": "中间会有一次「未打开」的提示，那不是报错。"},
        {"t": "note", "gap": 6, "text": "安装包 616 KB。App 必须待在「应用程序」里，桌面小组件才登记得住。"},
        {"t": "h2", "gap": 8, "text": "四步"},
        {"t": "bullet", "text": "① 双击 .dmg"},
        {"t": "bullet", "text": "② 把 App 拖进「应用程序」"},
        {"t": "bullet", "text": "③ 第一次打开，放行一次"},
        {"t": "bullet", "text": "④ 打开 App，加上桌面小组件"},
        {"t": "quote", "text": "装好之后，第一件事是拖一格试试。"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "第 1 步 / 4"},
        {"t": "h1", "text": "双击 .dmg"},
        {"t": "p", "text": "双击下载到的安装包，系统会挂载一块磁盘，访达窗口自己弹出来。"},
        img("01-dmg.png", caption="窗口里：App、说明、两个修复脚本。"),
        {"t": "step", "n": "1", "text": "先别急着双击 App。"},
        {"t": "step", "n": "2", "text": "「应用程序」是快捷方式，第 4 页会用到它。"},
        {"t": "quote", "text": "两个 .command 先放着，第 7 页再说。"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "第 2 步 / 4"},
        {"t": "h1", "text": "拖进「应用程序」"},
        {"t": "step", "n": "1", "text": "按住窗口里的 App 图标。"},
        {"t": "step", "n": "2", "text": "拖到左边栏的「应用程序」上，松手。"},
        {"t": "step", "n": "3", "text": "等一两秒，才 600 多 KB。"},
        img("02-install-dialog.png", h=250, caption="或者直接双击，它会问你——点「帮我装好」。"),
        {"t": "quote", "text": "600 KB，一秒就拷完了。"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "第 3 步 / 4"},
        {"t": "h1", "text": "第一次打开，会被拦一次"},
        {"t": "p", "text": "系统不认识这个 App 的开发者，所以先拦下——这不是报错，也不会损坏什么。"},
        img("03-gatekeeper.png", h=185, caption="点「完成」。千万别点「移到废纸篓」。"),
        {"t": "step", "n": "1", "text": "打开「系统设置」→「隐私与安全性」，往下滚。"},
        {"t": "step", "n": "2", "text": "看到「已阻止…」就点「仍要打开」，输密码。"},
        img("04-settings.png", h=150, caption="「仍要打开」就在这里。"),
        {"t": "quote", "text": "只拦第一次。以后直接双击就行。"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "第 4 步 / 4"},
        {"t": "h1", "text": "加上桌面小组件"},
        {"t": "step", "n": "1", "text": "先打开一次 App（它要把自己的小组件登记上）。"},
        {"t": "step", "n": "2", "text": "在桌面上右键 →「编辑小组件」。"},
        {"t": "step", "n": "3", "text": "搜 Little by Little，拖到桌面。"},
        img("widget-fresh.png", h=215, caption="大号最像一张纸条。"),
        {"t": "note", "text": "搜不到就双击包里的「修复小组件.command」，再试一次。"},
        {"t": "quote", "text": "大号最像一张贴在墙上的便条。"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "包里的两个脚本"},
        {"t": "h1", "text": "出问题时才用"},
        {"t": "h2", "text": "修复小组件.command"},
        {"t": "p", "text": "小组件在列表里搜不到、拖不上桌面时双击它：去掉系统的隔离标记、清掉失效的登记、重新登记并重启小组件服务。"},
        {"t": "h2", "gap": 4, "text": "诊断小组件.command"},
        {"t": "p", "text": "出问题时双击它：把系统版本、App 位置、签名、登记情况收集成一个 txt 放到桌面，方便发给作者看。"},
        {"t": "note", "text": "第一次双击脚本可能被拦：右键脚本 →「打开」→「打开」。它们只读信息、做登记，不会动你的日程。"},
        {"t": "bullet", "gap": 6, "text": "平时不用管这两个文件。"},
        {"t": "quote", "text": "用得上的那天，说明出了点小问题。"},
    ]},
]

# ══════════════════════════════════════════════════════
#  使用说明
# ══════════════════════════════════════════════════════
USAGE = [
    cover("使用", "每天一条时间轴，做完了打个勾\n不提醒、不评分、不催你", "hero.png",
          "打开 App 就能开始，不用设置"),

    {"blocks": [
        {"t": "kicker", "text": "一天是这样过的"},
        {"t": "h1", "text": "拖一下，写一句"},
        img("hero.png"),
        {"t": "bullet", "gap": 6, "text": "空白处拖一段：就是一件事，时间跟着拖走。"},
        {"t": "bullet", "text": "双击块：改名字。点 ✎：写地点、备注。"},
        {"t": "bullet", "text": "点块右上角的圆圈：打勾，划掉。"},
        {"t": "bullet", "text": "右键块：删除；整块上下拖动还能改时间。"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "一次加好几天"},
        {"t": "h1", "text": "批量加"},
        {"t": "p", "text": "同一件事要重复好几天时，别一天天拖。"},
        img("bulk-modal.png", h=300, caption="点 16、17、18，写一件事，就成了。"),
        {"t": "step", "n": "1", "text": "点日历上的日期，或拖一片、按住 Shift 选一段。"},
        {"t": "step", "n": "2", "text": "「从 / 到」填好范围，整段自动选上；再点「周中」收窄。"},
        {"t": "step", "n": "3", "text": "写标题、时间，点「加」。"},
        {"t": "quote", "text": "拖宽一点是两小时，拖窄一点是半小时。"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "桌面上"},
        {"t": "h1", "text": "一张卡片，点一下就打勾"},
        img("widget-fresh.png", h=245),
        {"t": "bullet", "gap": 6, "text": "点圆圈：直接打勾，不用开 App。"},
        {"t": "bullet", "text": "卡片会自己变高变矮，只留今天的事。"},
        {"t": "bullet", "text": "卡片底部的「晨跑 1/5」是这周的定期任务。"},
        {"t": "h2", "gap": 8, "text": "记不住的几个键"},
        {"t": "bullet", "text": "⌘T 回到今天　⌘[ / ⌘] 前后一天"},
        {"t": "bullet", "text": "⌃⌥L 在任何地方叫出卡片"},
    ]},

    {"blocks": [
        {"t": "kicker", "text": "底线"},
        {"t": "h1", "text": "东西都在自己电脑上"},
        {"t": "p", "text": "没有账号，没有同步，没有订阅。所有内容是你电脑上的一个 JSON 文件。"},
        {"t": "note", "gap": 6, "text": "~/Library/Application Support/Little by Little/store.json"},
        {"t": "h2", "gap": 8, "text": "搬家 / 备份"},
        {"t": "bullet", "text": "复制这个文件，就是全部。换电脑把它放回同一位置即可。"},
        {"t": "bullet", "text": "卸载：把 App 拖进废纸篓；想连数据一起清掉，再删上面那个文件夹。"},
        {"t": "space", "h": 6},
        {"t": "bullet", "text": "它不催你。今天没做完，明天那条线还会自己走过来。"},
        {"t": "quote", "text": "一天一天，慢慢来。"},
    ]},
]



# ══════════════════════════════════════════════════════
#  纯文字稿 ↔ 页面
# ══════════════════════════════════════════════════════
TXT = os.path.join(ROOT, "说明文字稿.txt")

KEYMAP = {"小标": "kicker", "大标": "h1", "小节": "h2", "正文": "p",
          "要点": "bullet", "提示框": "note", "手写句": "quote"}


def dump_txt(path=TXT, docs=(("安装说明", INSTALL), ("使用说明", USAGE))):
    out = [";; Little by Little 说明书文字稿 —— 直接改这里的文字，改完跑：",
           ";;   python3 scripts/make-pdf.py txt",
           ";;",
           ";; 「--- 」开头的一行 = 新的一页；「##### 」开头 = 新的一份文档。",
           ";; 每行格式是「标签：内容」，可用的标签：",
           ";;   小标 / 大标 / 小节 / 正文 / 要点 / 提示框 / 手写句",
           ";;   步骤：2 | 第几步的正文      图：01-dmg.png | 图说",
           ";;   分隔      空行（这两行不带冒号）",
           ";; 空行和 ;; 开头的行会被忽略，随便排版不影响结果。",
           ""]
    for title, pages in docs:
        out.append("##### " + title)
        out.append("")
        num = 0
        for page in pages:
            num += 1
            if page.get("cover"):
                out += ["--- 封面",
                        "标题：" + page["title"],
                        "副标题：" + page["subtitle"].replace("\n", "\n副标题："),
                        "图片：" + os.path.basename(page["image"]["path"]),
                        "小字：" + page.get("hint", ""), ""]
                continue
            out.append("--- 第 %d 页" % num)
            for b in page["blocks"]:
                t = b["t"]
                if t == "step":
                    out.append("步骤：%s | %s" % (b.get("n", "1"), b["text"]))
                elif t == "img":
                    name = os.path.basename(b["path"])
                    parts = [name]
                    if b.get("h"):
                        parts.append("h=%d" % b["h"])
                    if b.get("caption"):
                        parts.append(b["caption"])
                    out.append("图：" + " | ".join(parts))
                elif t == "rule":
                    out.append("分隔")
                elif t == "space":
                    out.append("空行")
                else:
                    label = {v: k for k, v in KEYMAP.items()}.get(t, t)
                    out.append("%s：%s" % (label, b["text"]))
            out.append("")
    with open(path, "w") as fh:
        fh.write("\n".join(out))
    print("文字稿: %s" % path)


def parse_txt(path=TXT):
    docs, pages, page, models = [], [], None, []
    with open(path) as fh:
        for raw in fh.read().splitlines():
            line = raw.rstrip()
            if not line.strip() or line.startswith(";;"):
                continue
            if line.startswith("#####"):
                if pages:
                    docs.append(pages)
                pages, page = [], None
                models.append(line[5:].strip())
                continue
            if line.startswith("---"):
                page = {"blocks": []}
                if line[3:].strip() == "封面":
                    page["cover"] = True
                pages.append(page)
                continue
            if page is None:
                continue
            key, _, val = line.partition("：")
            key, val = key.strip(), val.strip().replace("\\n", "\n")
            if page.get("cover"):
                if key == "标题":
                    page["title"] = val
                    continue
                elif key == "副标题":
                    page["subtitle"] = (page.get("subtitle", "") + "\n" + val).strip("\n")
                    continue
                elif key == "图片":
                    page["image"] = {"path": os.path.join(SHOTS, val)}
                    continue
                elif key == "小字":
                    page["hint"] = val
                    continue
                elif key in ("诉求", "引言"):
                    page["claim"] = (page.get("claim", "") + (" " if page.get("claim") else "") + val).strip()
                    continue
            if key in KEYMAP:
                page["blocks"].append({"t": KEYMAP[key], "text": val})
            elif key == "步骤":
                n, _, txt = val.partition("|")
                page["blocks"].append({"t": "step", "n": n.strip(), "text": txt.strip()})
            elif key == "图":
                parts = [x.strip() for x in val.split("|")]
                b = {"t": "img", "path": os.path.join(SHOTS, parts[0])}
                for seg in parts[1:]:
                    if seg.startswith("h="):
                        b["h"] = float(seg[2:])
                    elif seg:
                        b["caption"] = seg
                page["blocks"].append(b)
            elif key == "并排":
                parts = [x.strip() for x in val.split(";")]
                hh = 0.0
                items = []
                i = 0
                while i < len(parts):
                    seg = parts[i]
                    if seg.startswith("h="):
                        hh = float(seg[2:])
                        i += 1
                        continue
                    cap = parts[i + 1] if i + 1 < len(parts) and not parts[i + 1].startswith("h=") else ""
                    items.append({"path": os.path.join(SHOTS, seg), "caption": cap})
                    i += 2 if cap else 1
                page["blocks"].append({"t": "imgpair", "items": items, "h": hh or 160})
            elif key == "分隔":
                page["blocks"].append({"t": "rule"})
            elif key == "空行":
                page["blocks"].append({"t": "space", "h": 10})
            else:
                print("  看不懂这行，跳过：%s" % raw)
    if pages:
        docs.append(pages)
    return models, docs

def build(doc_key, pages, title):
    os.makedirs(TMP, exist_ok=True)
    for f in os.listdir(TMP):
        if f.startswith(doc_key) and f.endswith(".png"):
            os.remove(os.path.join(TMP, f))

    pngs = []
    for i, page in enumerate(pages, 1):
        p = dict(page)
        if not p.get("cover"):
            p["page"] = str(i)
            p["total"] = str(len(pages))
            p["foot"] = "Little by Little %s · %s" % (VERSION, title)
        jf = os.path.join(TMP, "%s%02d.json" % (doc_key, i))
        pf = os.path.join(TMP, "%s%02d.png" % (doc_key, i))
        with open(jf, "w") as fh:
            json.dump(p, fh, ensure_ascii=False)
        r = subprocess.run([MKPAGE, jf, pf], capture_output=True, text=True)
        # 第二遍：标题线与封面标题对齐（头齐），再用块间距铺到与封面底部同一线（尾齐）
        if not p.get("cover"):
            def render():
                with open(jf, "w") as fh:
                    json.dump(p, fh, ensure_ascii=False)
                return subprocess.run([MKPAGE, jf, pf], capture_output=True, text=True)

            p["shift"] = 0.0
            p["spread"] = 1.0
            r0 = render()
            m = re.search(r"H1Y (-?[0-9.]+)", r0.stderr or "")
            p["shift"] = round(float(m.group(1)) - 664.0, 2) if m else 0.0
            p["spread"] = 1.0
            gx = 0.0
            r = r0
            for _ in range(6):
                p["gapExtra"] = round(gx, 2)
                r = render()
                m = re.search(r"\(y=(-?[0-9.]+)\)", r.stderr or "")
                if not m:
                    break
                cur = float(m.group(1))
                if abs(cur - 96.0) <= 4:
                    break
                gx = max(0.0, gx + (cur - 96.0) / 6.0)
            # 间距铺不满时，先把图放大，再留一点呼吸感（块间距上限 18）
            if gx > 20:
                extra = gx - 20
                gx = 20.0
                pics = [b for b in p.get("blocks", []) if b.get("type") == "img"]
                if pics:
                    add = extra / len(pics)
                    for b in pics:
                        b["h"] = round(min(float(b.get("h") or 200) + add, 400), 1)
                    for _ in range(4):
                        p["gapExtra"] = round(gx, 2)
                        r = render()
                        m = re.search(r"\(y=(-?[0-9.]+)\)", r.stderr or "")
                        if not m:
                            break
                        cur = float(m.group(1))
                        if abs(cur - 96.0) <= 4:
                            break
                        gx = max(0.0, min(22.0, gx + (cur - 96.0) / 6.0))
            r = render()
        if r.returncode != 0 or "警告" in r.stderr:
            for line in r.stderr.strip().splitlines():
                print("  [%s p%d] %s" % (doc_key, i, line))
        if not os.path.exists(pf):
            print("  失败：%s" % pf)
            continue
        pngs.append(pf)

    out = os.path.join(ROOT, "pkg", "Little by Little %s.pdf" % title)
    imgs = [Image.open(p).convert("RGB") for p in pngs]
    imgs[0].save(out, "PDF", resolution=216.0, save_all=True, append_images=imgs[1:])
    print("PDF: %s  %d pages  %d bytes" % (out, len(imgs), os.path.getsize(out)))


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which == "dump":
        dump_txt()
    elif which == "txt":
        titles, docs = parse_txt()
        for t, pages in zip(titles, docs):
            build("ins" if t == "安装说明" else "use", pages, t)
    else:
        if which in ("all", "install"):
            build("ins", INSTALL, "安装说明")
        if which in ("all", "usage"):
            build("use", USAGE, "使用说明")
