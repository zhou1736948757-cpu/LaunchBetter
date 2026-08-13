# 任务包: E0 修复 LauncherStore 初始化编译阻塞

## 背景

当前 HEAD `e48d954c10871d1de24ec406d962dfea8a9cb3b2` 的完整工程 build 失败:

```text
LauncherStore.swift:103:9: error:
'self' used in method call 'rebuildCatalogIndex' before all stored properties are initialized
```

`LauncherStore.init` 在 `config` 与 `settingsStore` 初始化前调用了 instance method `rebuildCatalogIndex()`。这是 Stage E 之前的基线阻塞，不是 App Library 行为。

## 允许修改的文件

- `LaunchBetterApp/LauncherStore.swift`

禁止修改其它文件，禁止修改 `Launchpad_Back`，禁止提交、切换分支、reset、clean 或 push。

## 约束

- 保持当前初始化语义和首帧数据流。
- 不把 `rebuildCatalogIndex` 改成全局状态或新单例。
- 不引入 `DispatchQueue.main.sync`、不安全并发或无关重构。
- 按 AGENTS.md 规则使用显式初始化顺序。

## 验收标准

1. `LauncherStore` 编译通过。
2. `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 成功。
3. `Packages/LaunchCore`、`Packages/LaunchPlatform`、`Packages/LaunchUI` 现有测试不回归。
4. `git diff --check` 通过。

## 输出要求

返回改动文件和行数、假设、build/test 完整结果、偏差和未决问题。每个步骤使用 `[PROGRESS]` 汇报。不要提交 Git。
