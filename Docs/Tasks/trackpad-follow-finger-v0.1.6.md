# 任务包: 双指跟手翻页修复(v0.1.6)

## 背景
问题详情见 Docs/Issues/trackpad-follow-finger-problem.md(必读)。用户实测反馈"跟手还是有问题"。

## 允许修改的文件(禁止范围外)
- Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift
- Packages/LaunchUI/Sources/LaunchUI/ClickableCollectionView.swift
- Packages/LaunchUI/Sources/LaunchUI/PagingGridLayout.swift(仅当需要)
- Packages/LaunchCore/Sources/LaunchCore/PagingGestureSession.swift(仅当需要)

## 目标(按优先级)
1. [A] 触控板位移改用像素单位: `event.hasPreciseScrollingDeltas` 为 true 时用
   `event.scrollingDeltaX`(像素),否则退化用 `event.deltaX` 的提交制(鼠标滚轮)
2. [B] 跟手加阻尼系数(常量, ~0.5, 可调): 页面位移 = 手指累计位移 × 阻尼
3. [C] `.began` 时若 clip 不在整页(吸附动画中断中),先把 currentPage 校准到
   round(offset/pageWidth),再记 gestureBaseX —— 防基准错乱
4. [D] 横向跟手累计与纵向滚轮提交制分离,不复用同一 session 的累计状态互相污染
5. [E] 方向兼容系统自然滚动设置: 用 event.isDirectionInvertedFromDevice 修正符号
6. [F] 水平手势进行中后续 changed 事件不因单帧 deltaY 略大而退出跟手(会话内持续跟手)
7. [G] 评估横向橡皮筋影响; 若直接写 clip offset 被 NSScrollView 弹性修正导致
   跟手阻尼感异常, 设 scrollView.horizontalScrollElasticity = .none(如无影响则不做)

## 约束
- 遵循 AGENTS.md 全部规则(几何唯一真值走 GridGeometry.snapTarget, 不新增 main.sync,
  LaunchCore 无 AppKit)
- 搜索模式(垂直滚动)行为不得受影响
- momentum 阶段仍全拦截, 仅 momentum.ended 吸附; 一次手势最多一页
- 吸附阈值 35% 与 snapTarget 逻辑不变(除非你发现明显错误, 需报告)

## 必写测试
- 不改 PagingGestureSession 则保持其 7 测试通过; 若新增纯逻辑(如阻尼/方向换算),
  必须在 LaunchCore 加 XCTest
- 全部现有测试不得回退(LaunchCore: 96 swift-testing + 33 XCTest)

## 验收
- xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build 成功
- LaunchCore swift test 全绿
- 主对话会独立跑 pagetest/smoke 验证

## 禁止
- 不修改 LaunchBetterApp/ 任何文件(诊断工具保持不动)
- 不提交 git、不切换分支
- 不修改 /Users/mac/Projects/Launchpad_Back
- 不引入新依赖

## 输出要求
返回: 改动文件清单 / 技术假设清单(逐条) / build+test 结果 / 与任务的偏差 / 未决问题
