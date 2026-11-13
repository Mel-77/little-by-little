#!/usr/bin/env python3
"""手搓小组件的 App Intents 元数据。

Xcode 会在构建时跑 appintentsmetadataprocessor，把扩展里所有 AppIntent 的
描述写成 Contents/Resources/Metadata.appintents/extract.actionsdata，
系统（WidgetKit / linkd）靠它才知道「这个按钮按下去要跑哪个 intent」。
本机只有 Command Line Tools，没有这个工具，于是我们按同样的格式手写一份。

格式是逆向系统扩展得来的（对照 /System/Applications/Reminders.app 的
RemindersWidgetExtension.appex/Contents/Resources/Metadata.appintents）。
改了 intent 的类名、参数名或参数类型，这里要跟着改。

用法：make-appintents-metadata.py <输出目录>（例如 .../LittleByLittleWidget.appex/Contents/Resources）
"""
import json
import os
import sys

MODULE = "LittleByLittleWidget"
INTENT = "CompleteBlockIntent"
# Swift 修饰名：模块名 08"LittleBy" + A(替换 Little) + 6"Widget" + 类型名
MANGLED = "08LittleByA6Widget19CompleteBlockIntentV"

# 系统用的原始类型编号：1 = Bool，12 = String（从系统 appex 的元数据里统计出来的）
BOOL, STRING = 1, 12


def primitive(type_id, name, title, optional=False):
    return {
        "valueType": {"primitive": {"wrapper": {"typeIdentifier": type_id}}},
        "capabilities": 0,
        "isOptional": optional,
        "title": {"key": title},
        "dynamicOptionsSupport": 0,
        "isInput": False,
        "inputConnectionBehavior": 0,
        "typeSpecificMetadata": [],
        "name": name,
        "resolvableInputTypes": [],
    }


def metadata():
    return {
        "assistantIntents": [],
        "actions": {
            INTENT: {
                "outputFlags": 0,
                "effectiveBundleIdentifiers": [],
                "availabilityAnnotations": {"LNPlatformNameWildcard": {"introducedVersion": "*"}},
                "parameters": [
                    primitive(STRING, "blockID", "日程"),
                    primitive(BOOL, "done", "完成"),
                ],
                "isDiscoverable": False,
                "title": {"key": "更新日程完成状态"},
                "mangledTypeNameByBundleIdentifierV2": {},
                "assistantDefinedSchemaTraits": [],
                "presentationStyle": 0,
                "mangledTypeNameByBundleIdentifier": {},
                "systemProtocolMetadata": [],
                "openAppWhenRun": False,
                "fullyQualifiedTypeName": "%s.%s" % (MODULE, INTENT),
                "identifier": INTENT,
                "descriptionMetadata": {
                    "searchKeywords": [],
                    "descriptionText": {"key": "勾选或取消一件事"},
                },
                "isAuthPolExplicit": False,
                "systemProtocols": [],
                "mangledTypeName": MANGLED,
                "typeSpecificMetadata": [],
                "authenticationPolicy": 0,
                "mangledTypeNameV2": MANGLED,
                "requiredCapabilities": [],
                "visibilityMetadata": {"assistantOnly": False, "isDiscoverable": False},
                "assistantDefinedSchemas": [],
                "systemProtocolMetadataV2": [],
            }
        },
        "version": 1,
        "autoShortcuts": [],
        "negativePhrases": [],
        "assistantIntentNegativePhrases": [],
        "shortcutTileColor": 14,
        "assistantEntities": [],
        "entities": {},
        "enums": {},
        "generator": {"name": "little-by-little-handmade", "version": "1"},
        "queries": {},
    }


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    meta = os.path.join(out, "Metadata.appintents")
    os.makedirs(meta, exist_ok=True)
    with open(os.path.join(meta, "extract.actionsdata"), "w") as f:
        json.dump(metadata(), f, ensure_ascii=False)
    with open(os.path.join(meta, "version.json"), "w") as f:
        json.dump({"version": "3.0", "toolsVersion": "handmade"}, f, ensure_ascii=False, indent=2)
    print("    App Intents 元数据 -> %s" % meta)


if __name__ == "__main__":
    main()
