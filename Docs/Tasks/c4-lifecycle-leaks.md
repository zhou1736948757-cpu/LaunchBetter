# 任务包 C4: 生命周期/泄漏审计

## 背景
Stage C §C4。审计全部长期资源在 show/hide/退出时正确清理, 不累积。

## 允许修改的文件(仅当发现真实泄漏, 最小修复)
- Packages/LaunchUI/Sources/LaunchUI/(PagingInteractionController/FrameCoordinator/PageSnapAnimator)
- Packages/LaunchPlatform/Sources/LaunchPlatform/(GestureCaptureEngine/DirectoryMonitor/IconRepository/DiskCacheWriter)
- LaunchBetterApp/(ActivationCoordinator/ThreeFingerDragCoordinator)
- 对应测试(如需)

## 审计清单
- CADisplayLink / NSView.displayLink: 停止后 invalidate(interruption/停止路径)
- PagingInteractionController: 停止 display link; 无残留状态
- FrameCoordinator(拖拽): stop() invalidate
- gesture callbacks: engine.stop/uninstall 清回调
- Multitouch subscription: 私有 MTDevice 停止
- NotificationCenter observers: CellRootView 已改标准 API(无 observer); 其他 observer 清理
- DirectoryMonitor: stop
- IconRepository: memory pressure source cancel; DiskCacheWriter shutdown
- FolderViewController observers
- show/hide 重复: 不累积 work(display link/任务)

## 验收
- 审计报告: 每项生命周期状态 + 是否有泄漏
- 发现的真实泄漏最小修复 + 测试
- 全测试绿; build 成功

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm。搜索用 grep 工具, 读用 read 工具。
验证: swift test / xcodebuild build。

## 禁止
不提交 git; 不改 Launchpad_Back; 不改范围外文件

## 输出
审计表(每资源: start/stop/shutdown 路径 + 泄漏判定)/修复/测试结果; 每步 [PROGRESS]
