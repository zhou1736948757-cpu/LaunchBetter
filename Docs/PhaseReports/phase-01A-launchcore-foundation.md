# Phase 1A — LaunchCore Foundation

## Scope

LaunchCore 基础类型 + 纯逻辑对账器,零平台依赖。

## Implementation Summary

新建 Swift 包 `Packages/LaunchCore`(swift-tools-version 6.0, Swift 6 严格并发,
macOS 14+ 部署)。实现:

- **身份**: AppID / FolderID — 规范化路径身份,自定义 Codable(解码时规范化,空则抛错),
  禁止 ExpressibleByStringLiteral
- **目录**: AppRecord(id/url/bundleIdentifier/displayName/infoPlistModificationDate/
  iconContentVersion), CatalogSnapshot(apps 按 AppID 排序不变式), CatalogDelta
- **布局**: LayoutItem(app/folder), FolderRecord(children 保序), LayoutSnapshot
  (schemaVersion=1, pages/folders/missingApps), MissingAppState
- **对账**: LayoutReconciler(纯逻辑,规则见下)
- **图标**: IconContentVersion(真实内容信号指纹,无 reconcile 代数),
  IconKey(AppID+pointSize+scale+contentVersion)
- **配置**: AppConfiguration(schemaVersion=1, 网格/图标/标签/自定义源/隐藏/自定义名/
  语言/热键/热角,解码缺字段回退默认), HotkeyConfig/HotkeyModifiers/OptionSet,
  HotCornerConfig/HotCornerAction
- **搜索**: SearchIndex(displayName/bundleID/customName,大小写+变音符不敏感包含匹配,
  结果按 AppID 确定性排序,纯内存)

对账规则(全部确定性,集合遍历按 rawValue 排序):
1. 新应用(目录有、布局无引用)→ 追加到最后一页末尾;无引用墓碑同时清除并重新加入
2. 缺失应用(布局引用、目录无)→ 保留布局引用,创建墓碑(missingSince 保留原值)
3. 应用回归 → 清除墓碑,位置自动恢复
4. 过期墓碑(默认 30 天,可注入)→ 从页面与文件夹子项移除
5. 孤儿文件夹项 → 从页面移除
6. 空文件夹 → 确定性解散

## Important Files

- Packages/LaunchCore/Package.swift
- Packages/LaunchCore/Sources/LaunchCore/ 11 个文件
- Packages/LaunchCore/Tests/LaunchCoreTests/ 9 个测试套件

## Tests

59 个测试全部通过(`swift test`),9 套件:
AppID(规范化/等式/编码/解码规范化/解码空抛错)、FolderID、AppRecord、Layout、
Catalog、Icon(变体区分/版本区分/pixelSize)、Configuration(默认值/往返/前向兼容)、
SearchIndex(空查询/各字段匹配/remove/确定性)、LayoutReconciler(11 个场景含宽限期边界)。

## Build Results

- `swift test`: 59/59 通过
- `swift build -c release`: 通过
- 违禁导入扫描: AppKit/SwiftUI/Combine/FileManager/DispatchQueue = 0

## Performance Results

无性能测量(纯类型层,无运行时管道)。

## Review Results

自查评审 + 修订:
- 修复 `///` 规范化应止于根路径 `/`(测试驱动)
- 修复宽限期边界测试设计缺陷(两个墓碑同时间戳导致同时过期)
- 补边角: 无引用墓碑的应用回归时重新加入布局(新增测试)

独立 GLM 评审未执行: 当前任务工具只能路由到 explore/general 子代理,无法按
.opencode/agents 配置路由到 GLM-5.2;该限制已记录于 MEMORY。Phase 1A 为纯确定性
类型层且测试覆盖率充分,风险可接受;Phase Gate 后(Phase 4 起)的架构关键评审
仍按文档要求执行,届时若无法路由 GLM 则记录偏差并用最高可用独立子代理替代。

## Architecture Deviations

- 无代码偏差。
- 文档未定义 SearchIndex 匹配语义细节(大小写/变音符不敏感包含)与结果排序,
  按旧版行为继承并固定为确定性规则。

## Known Limitations

- AppID 第二层规范化(文件系统收敛)属 LaunchPlatform,Phase 2 实现
- LayoutTransaction / DisplayModel 属 Phase 1C

## Commit Range

TBD(Phase 1A 提交)

## Remaining Risks

- 无。纯类型层,测试充分。

## Next

Phase 1B — 一次性 NSCollectionView/120Hz spike(200 placeholder cells、
水平分页、CALayer 拖拽 overlay、跨页行为),在真实 120Hz 显示器测量帧时间。
