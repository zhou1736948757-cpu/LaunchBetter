# 任务包 B3: 右键菜单补全(Reveal in Finder / Get Info)

## 背景
LaunchBetter v0.2.3。当前应用右键菜单已有: 加入文件夹/新建文件夹/隐藏/重命名/移到废纸篓。
缺: Reveal in Finder、Get Info。Stage B §B3。

## 允许修改的文件(禁止范围外)
- Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift(contextMenu)
- Packages/LaunchUI/Sources/LaunchUI/L10n.swift(新菜单项文案 en/zh-Hans/zh-Hant)
- 测试: Packages/LaunchUI/Tests/LaunchUITests/(如可测)

## 需求
1. App 右键菜单新增:
   - Reveal in Finder: NSWorkspace.shared.activateFileViewerSelecting([url]) 标准 API
   - Get Info: 用安全方式(AppleScript "tell application \"Finder\" to open information window
     of (POSIX file ...)") 或 AppleScript 文本安全编码; 若 AppleScript 风险高, 用标准方案并文档化。
     禁止 shell 注入(用 osascript -e 带参数? 不, 用 NSAppleScript 或 AppleScript 字符串安全构造)
   - 保留现有项
2. Folder 菜单: 保留重命名/解散
3. 本地化新菜单项(三语言)
4. 路径安全: 用规范 AppID URL; 不 Trash 系统受保护应用(现有行为保持)

## 约束
- 无 shell 注入; 路径经 URL/规范 AppID
- 不改菜单现有行为; 不改拖拽/文件夹逻辑
- L10n 三语言补齐

## 验收
- 菜单含 Reveal in Finder / Get Info; 现有项不丢
- 本地化三语言
- UI 测试(菜单结构/无障碍)绿; 全测试绿; build 成功
- Reveal/Get Info 真机动作标 MANUAL_VERIFICATION(自动化无法验证 Finder 窗口)

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm。搜索用 grep 工具, 读用 read 工具。
验证: swift test / xcodebuild build。

## 禁止
不提交 git; 不切换分支; 不改 Launchpad_Back; 不改 B3 范围外文件

## 输出
改动文件清单/假设/测试结果/偏差/未决; 每步 [PROGRESS]
