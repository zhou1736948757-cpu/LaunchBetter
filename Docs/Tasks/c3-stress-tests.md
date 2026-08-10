# 任务包 C3: 合成压力测试(100/250/500 apps)

## 背景
Stage C §C3。为 DisplayModel/SearchIndex/Layout/Reorder/Folders/snapshot/本地化元数据/垂直模式(如有)
建立确定性合成 fixtures, 覆盖 100/250/500+ apps。不需要 500 个真实应用。

## 允许修改的文件
- Packages/LaunchCore/Tests/LaunchCoreTests/ 新增 StressTests.swift(合成 fixtures + 断言)
- Packages/LaunchCore/Sources/ 不改(仅测试)

## 需求
- 合成 CatalogSnapshot(LayoutSnapshot)辅助生成 N apps(M 页, 含 folder/隐藏/缺失样本)
- 测试: DisplayModel 派生(页数/容量/扁平序)、SearchIndex(查询 N 规模)、LayoutTransaction
  reorder/文件夹移动(跨页)、snapshot 构建不崩溃、deterministic(同 seed 同结果)
- 100/250/500 三个规模; 断言正确性(非仅"不崩溃")
- 保持测试时间合理(< 数秒/规模)

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm。搜索用 grep 工具, 读用 read 工具。
验证: cd Packages/LaunchCore && swift test。

## 禁止
不提交 git; 不改生产代码; 不改 Launchpad_Back; 不改范围外文件

## 输出
改动/假设/测试结果/耗时/偏差; 每步 [PROGRESS]
