# Little by Little · 一点点来

一个 macOS 日程记录与桌面待办应用。在时间轴上拖出日程，完成后直接在桌面小组件勾选。

## 下载与安装

当前版本：**2.7.2**。在本仓库的 **Releases** 下载 DMG。

- 支持 macOS 14 或更新版本，包含 Apple 芯片和 Intel 架构。
- 将应用拖入“应用程序”，再打开一次，随后在桌面右键 → 编辑小组件 → 搜索 Little。
- 使用者不需要安装 Xcode，也不需要 AI 会员。
- 此版本使用开发签名，尚未经过 Apple 公证。若系统阻止打开，请先确认来源，再使用“系统设置 → 隐私与安全性 → 仍要打开”。公司管理的电脑可能不允许运行。
- 本机验证不代表所有 Mac 均兼容；欢迎通过 Issues 反馈系统版本、复现步骤及去除隐私后的截图。

## 功能

- 拖动时间轴创建日程，拖动日程或边缘调整时间。
- 完成状态、备注、颜色和删除。
- 批量选择多个日期添加日程。
- 定期任务与完成情况总结。
- 桌面 WidgetKit 小组件：直接勾选、取消，状态同步到应用。
- 菜单栏今日卡片。
- 数据存储在本机；本版没有截图 OCR 导入功能。

## 2.7.2

从 DMG 或系统临时运行目录启动时，提示安装到“应用程序”，避免小组件登记到会消失的临时路径。

## 数据与升级

主数据：`~/Library/Application Support/Little by Little/store.json`。
备份时退出应用后复制此文件。桌面小组件通过签名授权的 App Group 交换快照与操作。
升级后打开应用一次，让小组件刷新；不要同时运行多个版本。

完全退出应用后，小组件的勾选操作会保留，下一次打开应用时合并到主数据。

## 从源码构建

需要完整 Xcode、macOS SDK、App Intents 元数据工具，以及有效的 Apple Development 签名证书。
“运行已编译应用不需要 Xcode”与“从源码构建需要 Xcode”是不同的条件。

本仓库当前 App Group 标识属于原作者团队。自行构建前，请将以下文件中的 Team ID 和 App Group 改为自己的配置，并保持一致：

- `Info.plist`
- `SourcesWidget/Info.plist`
- `Sources/app.entitlements`
- `SourcesWidget/widget.entitlements`

```bash
./build.sh
# 显式选择证书时：
LBL_SIGN_IDENTITY="你的代码签名证书标识" ./build.sh
```

生成应用位于 `build/Little by Little.app`。打包脚本为 `scripts/make-package.sh`，其 Finder 排版步骤可能触发自动化权限提示。

## 源码结构

- `Sources/`：AppKit 外壳、存储与小组件刷新。
- `SourcesWidget/`：WidgetKit 界面与交互。
- `Resources/`：本地 HTML、CSS、JavaScript。
- `scripts/`：构建辅助与打包。
- `tests/`：存储回归测试。

## 反馈

请提供系统版本、芯片类型、安装位置和复现步骤。不要提交日程数据、密码、证书私钥或未脱敏的诊断日志。
