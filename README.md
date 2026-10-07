# 墨砚 · iOS

参考相邻 `inkstone` 桌面项目实现的原生 SwiftUI 移动端。支持 iOS / iPadOS 17 及以上，无第三方运行时依赖，数据保存为 UTF-8 Markdown 文件。

## 打开与运行

1. 使用 **Xcode 16 或更新版本**打开 `Inkstone.xcodeproj`。
2. 选择 `Inkstone` scheme 与 iPhone / iPad 模拟器后运行。
3. 真机运行时，在 Signing & Capabilities 中选择自己的开发团队，并按需修改 Bundle Identifier。

也可以一条命令构建、安装并启动模拟器：

```sh
./scripts/run-simulator.sh 'iPhone 17e'
# iPad：
./scripts/run-simulator.sh 'iPad mini (A17 Pro)'
```

不传设备名称时优先选择已启动的 iPhone，存在多个匹配时需指定名称或 UDID。脚本会自动使用 `/Applications/Xcode.app`，无需全局切换 `xcode-select`；显式设置的 `DEVELOPER_DIR` 优先。兼容旧版 Simulator 与 Xcode 27 的 Device Hub。

```sh
open Inkstone.xcodeproj
# 完整 Xcode 环境：
xcodebuild -project Inkstone.xcodeproj -scheme Inkstone \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

仓库包含生成后的工程，不需要安装 XcodeGen 或 CocoaPods。添加 App 源文件后运行 `python3 scripts/generate_project.py` 更新工程。

## 已实现

- 本地笔记库；通过系统「文件」选择外部文件夹，持久化访问书签。
- 新建 Markdown 笔记、通过路径创建子文件夹、每日笔记。
- 全文搜索（多个关键词同时匹配）、标签、收藏、最近修改排序。
- 原生源码编辑、基础 Markdown 阅读、任务勾选、手动保存。
- Wiki 双链、别名、反向链接和大纲；同名目标存在歧义时提示，不随机跳转。
- UTF-8 Markdown 导入与系统文件导出；同名导入拒绝覆盖。
- 450 毫秒防抖恢复草稿，保存前版本和已删除文件的本机恢复记录。
- 所有恢复均创建副本；保存和删除前比对原文，检测外部修改或删除。
- 浅色 / 深色外观跟随系统；中文界面与辅助功能标签。

## 与桌面配合

在设置中选择包含桌面笔记的文件夹，或导入桌面 `.md` 文件。iCloud Drive 等文件提供商负责设备间传输；本应用只协调本机文件访问并重新扫描文件。外部库不会写入桌面 `.inkstone` 元数据；移动端的草稿、历史、收藏独立存放。

打开笔记后，如果另一个应用修改了原文，点击保存会提示冲突。可通过笔记菜单「另存副本」保存移动端内容，再重新打开原文件核对。前台激活和下拉刷新会扫描最新内容；编辑器不会自动替换正在编辑的正文。

**不包含桌面 WebDAV 同步协议。** 桌面使用内容寻址对象、版本化 manifest、条件提交和设备基线；本版不会向这些端点写入普通 Markdown 文件。文件提供商的跨设备冲突和传输时机仍由提供商管理，不能把本机文件协调视为跨设备事务。

## 保存与恢复

点击编辑器顶部勾号写入原文件。尚未正式保存的编辑进入独立草稿；关闭时可选择保存或仅保留草稿。退出到后台也会尝试落盘，强制终止前尚未完成的写入不保证保留。

历史和已删除正文存放在应用私有 Application Support 中，**不会同步到桌面，也不能代替备份**。卸载应用会删除这些记录。当前版本不自动清理历史；大量长期编辑会增加本机占用。

本地笔记位于应用 Documents/墨砚笔记，支持系统文件共享。外部文件夹采用安全作用域书签与 `NSFileCoordinator`；笔记读写在 `Vault` actor 上串行执行，文件写入使用原文比对和原子替换。扫描跳过隐藏文件与符号链接，单篇笔记上限 8 MB，无法读取的文件会在设置显示原因。

## 阅读与兼容范围

阅读支持标题、段落、行内强调/链接/代码、代码块、引用、无序列表、分隔线与任务。Wiki `[[文件夹/笔记|别名]]` 与标签兼容；支持正文 `#标签` 及 frontmatter 单行 `tags: [标签一, 标签二]`。

尚未实现：桌面实时预览模式、图片和附件展示、表格排版、数学公式、嵌入笔记、完整 YAML、Markdown 相对文件链接跳转、标题锚点滚动、链接自动更新、重命名/移动界面、桌面历史格式、整库备份和后台云同步。上述原始 Markdown 保留不变，可在源码模式编辑。大纲目前用于查看结构。

## 验证

```sh
./scripts/check.sh
```

测试使用独立临时目录，不读取用户笔记。包含 Unicode/换行保真、草稿重启恢复、保存历史、删除恢复、同名文件保护、外部修改与删除冲突、路径越界和符号链接、坏编码提示、标签和双链歧义。

Swift Package 还会编译 `InkstonePreview`，用于在 macOS SDK 下检查共享 SwiftUI 代码。它不是 iOS 模拟器。只有 Command Line Tools 的机器可运行核心测试；脚本包含当前机器缺少宏插件时的 SDK 选择兼容处理。

2026-10-07 Xcode 安装后补验：Xcode 27.0 / iOS 27.0 模拟器构建通过，15 项核心回归通过；iPhone 17e 已验证新建、Unicode 正文保存、阅读任务勾选、历史恢复、草稿持久化与重启后恢复；iPad mini 已验证启动、横竖屏首页及横屏阅读。修复了指定设备构建时 App 与 Swift 包架构不一致的问题。

**真机签名安装、中文输入法组合输入、iCloud/第三方文件提供商同步仍待验收**。CI 已配置，尚未有远端执行结果。详细验证范围和剩余清单见 `docs/TESTING.md`。

## 目录

- `App/`：SwiftUI 页面、应用状态、文件导入导出与资源。
- `Sources/InkstoneCore/`：文件仓库、元数据解析、搜索与双链索引。
- `Tests/InkstoneCoreTests/`：Swift Testing 回归测试。
- `scripts/`：项目生成、验证、桌面图标规格转换。
- `Inkstone.xcodeproj/`：共享 Xcode scheme 与 iOS 工程。

沿用桌面端「墨砚」名称、青色强调色及正式图标；图标来源与许可见 `NOTICE` / `LICENSE`。
