# 任务包 A14: DisplayItem 稳定身份 — folder 用 FolderID, children 作 payload

## 背景
Luna 设计门(IMPLEMENT): `DisplayItem.folder(FolderID, visibleChildren: [AppID])` 把 children
编入 Hashable 身份 → Folder F [A,B] 与 [A,B,C] 是不同 Diffable 身份 → 子项变化表现为
delete+insert、文件夹 cell/thumbnail 无法稳定复用、可能 flicker。
修复: folder item 用稳定 FolderID 身份, children 作独立 payload。

## 允许修改的文件(禁止范围外)
- Packages/LaunchCore/Sources/LaunchCore/DisplayModel.swift
- Packages/LaunchCore/Sources/LaunchCore/LayoutTransaction.swift
- Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift(所有 .folder 匹配)
- Packages/LaunchUI/Sources/LaunchUI/FolderViewController.swift
- Packages/LaunchUI/Sources/LaunchUI/AppCellView.swift(configureFolder 缩略图取 children 的方式)
- Packages/LaunchUI/Sources/LaunchUI/DragController.swift(如 .folder 匹配)
- 测试: LaunchCoreTests + LaunchUITests 对应

## 设计
1. `DisplayItem.folder(FolderID)`(稳定身份; 不再带 children)
2. DisplayModel 保留独立 payload 查询(`folderVisibleChildren(id)` 已存在; 构造 pages 时 folder 只放 id)
3. LayoutTransaction: Preview.slots / finalize / changedPages 需传递或比较独立 payload——
   文件夹 payload(children)变化不得改变 folder item 的 Diffable 身份(identity 不变, payload 单独刷新)
4. UI 取文件夹缩略图/子项: 从 DisplayModel payload 或 store.folderChildren(id), 不经 item 关联值

## 约束
- 拖拽身份: LayoutTransaction 已按 FolderID 匹配(flatIndex/folderSlotIndex), 保持
- 空文件夹/隐藏子项场景正确
- 搜索/布局/源隐藏语义不变
- LaunchCore 仍无 AppKit

## 必写测试
- 同一 FolderID 改 children: identifier 不变; 无 delete/insert; payload 刷新一次
- 拖拽(source folder / destination folder)不回归
- 空文件夹 / 全部子项隐藏
- 文件夹缩略图(children 变化后正确)
- 搜索
- 既有 LayoutTransaction/DisplayModel 测试不回归

## 验收
- LaunchCore/Platform/UI 全测试绿; xcodebuild build 成功
- 拖拽 UX 无回退; 文件夹视觉无 flicker(代码/测试层面验证 identity 稳定)

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm。搜索用 grep 工具, 读用 read 工具。
验证: swift test / xcodebuild build。

## 禁止
不提交 git; 不切换分支; 不改 Launchpad_Back; 不改 A14 范围外文件

## 输出
改动文件清单/假设/测试结果/偏差/未决; 每步 [PROGRESS]
