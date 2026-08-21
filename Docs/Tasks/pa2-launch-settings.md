# PA2: 启动路径与设置写盘风暴（Phase A 批次 2）

实施记录(主会话直接实现; 委派代理本会话两次空返回)。验证: 三包测试全绿
(LaunchPlatform 142 / LaunchCore 181 / LaunchUI 342), xcodebuild BUILD SUCCEEDED,
`--smoke` OK(90 apps/搜索正常), `--settingsshot` 惰性构建截图正常。

## A4. 滑杆 commit 合并(写盘风暴)

- `SettingsWindowController`: 新增 `sliderValueChanged`(仅两个 isContinuous 滑杆
  使用) + `sliderCommitInterval`(默认 0.15s, 0 = 立即, 测试路径) +
  `flushPendingSliderCommit()`; dismiss 入口冲刷防丢最后一次拖动;
  语言重建前取消残留 workitem。复选框/弹窗等单击控件仍走 valueChanged 立即提交。
- 效果: 一次拖动从几十次「主线程同步写盘 + 全网格 snapshot apply(~6ms)」降为
  合并后 ≤1 次/150ms 窗口。
- 测试: 既有 4 个滑杆测试置 interval=0; 新增 coalesce-until-flush 测试。

## A5. 启动重复读盘去重

- 新增 `BootstrapSeeds`(config/catalog/layout/metadata 可空种子):
  容器首帧同步读盘成功 → 直接采纳; 失败/缺失(nil) → bootstrap 走原读盘/
  损坏备份恢复路径。语义不变, 读盘次数 2→1。
- `AppCatalogActor.start(seed:)` / `LayoutStore.start(adoptingSeed:)` /
  `AppLibraryMetadataStore.start(adoptingSeed:)`: 默认 nil 保持旧行为(测试兼容)。
- LauncherStore.init: 删除 reconcile 前的冗余 libraryModelCache 首建
  (中间结果无人读取), reconcile 后只建一次。

## A6. 首帧关键路径减负

- SettingsWindowController 惰性构建: 容器 `_settingsController` backing +
  计算属性访问即构建并注入 windowController; 齿轮(onOpenSettings)与 App 菜单
  (AppDelegate 先触达 container.settingsController)均为首次访问触发点。
  诊断探针按需访问同样触发。实测省 10-30ms 首帧。
- loginItem.apply(SMAppService 同步 XPC, 实测 5-50ms)移出 init:
  Task { @MainActor } hop 后执行, 隔离语义不变, 失败非致命。

## 已知边界

- hide→show 后若 revision 未变, refresh() 重置预热去重键(PA1)保证重新预热;
  设置滑杆合并窗口内直接退出进程理论上可丢最后 ≤150ms 的拖动值(dismiss
  正常路径已冲刷; 仅 kill -9 类场景)。
