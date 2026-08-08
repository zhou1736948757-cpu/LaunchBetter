# Phase 8 — Multitouch / Global Activation

## Scope

四指捏合手势引擎(MultitouchSupport 隔离)、全局热键(Carbon)、激活协调器;
Minimum Usable Release Gate 评估。

## Implementation Summary

- **PinchAnalyzer(纯逻辑)**: 触点样本 → 质心平均距离 → 相对幅度;
  ≥4 指、阈值 0.18、冷却 0.2s(§91 legacy 参数, 待实测复核);手指离开重置手势
- **MultitouchSupport(窄 C 包装)**: dlopen/dlsym 私有框架、MTTouch 布局声明、
  优雅不可用(init?)、C 回调非捕获 + 全局回调盒(签名无 context 参数)、
  输入监控权限检测(启动 3s 无回调 → waitingForPermission)
- **GestureCaptureEngine**: 回调(系统线程)→ 最新帧串行消费 → GestureEvent;
  与 UI/Store 完全解耦(§115);状态机 unavailable/running/waitingForPermission
- **GlobalHotkey**: Carbon RegisterEventHotKey(Cmd+L, 注册成功已验证),
  InstallEventHandler, 显式 start/stop
- **ActivationCoordinator(应用层)**: 手势/热键 → show/hide/toggle 决策;
  旧版 LaunchHistory 冲突检测(已实测触发警告);
  等待权限时输出系统设置指引
- Swift 6 环境事实: 自定义 struct 不能出现在 @convention(c) 签名(原始指针+
  assumingMemoryBound);类方法内定义带指针绑定的 C 闭包会使编译器崩溃
  (文件级非捕获函数规避);嵌套可选指针类型触发编译器 signal 6

## Important Files

- Packages/LaunchPlatform: PinchAnalyzer / MultitouchSupport / GestureCaptureEngine / GlobalHotkey
- LaunchBetterApp: ActivationCoordinator
- Tests: PinchAnalyzerTests(7)

## Tests

96 + 86 = 182 全绿(新增 7 个捏合分析: 少指/稳定/扩张/收缩/冷却/重置/离表过滤)

## Build Results

- 两包 swift test 全绿;xcodebuild Debug SUCCEEDED
- 冒烟: 热键 Cmd+L 注册成功(registered=true)、旧版冲突警告触发、
  手势状态正确报告(未授权 → 无设备)

## Performance Results

- 回调高频路径: 仅最新帧消费 + 纯计算(无主线程跳转), 符合 §88

## Review Results

- 自查: 4 个 Swift 6 工具链崩溃/限制均以确定性方案规避(已记录 MEMORY)

## Architecture Deviations

- 无。引擎只发事件, 协调器决策(§115)
- 热键暂固定 Cmd+L(设置化属 Phase 9)

## Known Limitations

- **四指手势真实验证待用户授予输入监控权限(TCC)**: 系统设置 → 隐私与安全性 →
  输入监控 → 启用 LaunchBetter。未授权时 MTDeviceCreateList 无设备返回。
- 测试触控板前需退出旧版 LaunchHistory(冲突警告已实现)

## Commit Range

TBD(Phase 8 提交)

## Remaining Risks

- 手势参数(0.18/0.2s)为 legacy 值, 授权后需实测复核

## Next

**Minimum Usable Release Gate 评估**(进行中)→ 通过后预发布审计 + 转公开 +
v0.1.0;Phase 9 外围功能。
