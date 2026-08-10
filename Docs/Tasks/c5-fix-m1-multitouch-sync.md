# 任务包 C5 修复 M1: Multitouch @unchecked Sendable 生命周期同步(Luna MAJOR)

## 背景
Luna C5: GestureCaptureEngine/MultitouchSupport 的 @unchecked Sendable 生命周期未完全同步:
- onThreeFingerGesture/onGesture 在 engine.start() 后安装, 回调线程读无锁(数据竞争)
- 全局 contactCallbackBox 读写无同步
- stop() 清除 wrapper 后停止设备, 迟到回调仍可发事件(C4 已清 stop 回调, 但 box/install 竞争仍在)
- start/stop 并发交错窗口

## 允许修改的文件(禁止范围外)
- Packages/LaunchPlatform/Sources/LaunchPlatform/GestureCaptureEngine.swift
- Packages/LaunchPlatform/Sources/LaunchPlatform/MultitouchSupport.swift
- LaunchBetterApp/ThreeFingerDragCoordinator.swift(如需 install/uninstall 加锁)
- 测试: Packages/LaunchPlatform/Tests/LaunchPlatformTests/

## 要求
1. 统一生命周期锁/状态机保护: callback 属性读写、wrapper、timer、全局 contactCallbackBox
2. 回调安装(install/uninstall)与 start/stop 同步(引擎内部锁; 或在安装点加锁/顺序化)
3. stop: 等待回调静默/清 box 后再清理; 迟到回调不派发(现有 stop 清回调保持)
4. 显式 shutdown(); 无 data race(TSan 逻辑可验证); 无行为回归(三指/四指仍工作)
5. 测试: 并发 start/stop/restart 无竞争(逻辑断言); stop 后无事件; install 与回调并发安全

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm、which。搜索用 grep 工具, 读用 read 工具。
验证: cd Packages/LaunchPlatform && swift test; xcodebuild build。

## 禁止
不提交 git; 不改 Launchpad_Back; 不改 M1 范围外文件

## 输出
改动/假设/测试结果/偏差; 每步 [PROGRESS]
