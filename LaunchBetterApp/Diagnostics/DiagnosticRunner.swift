import AppKit
import Darwin
import LaunchCore
import LaunchUI

/// 诊断模式分派器(A10): 依据命令行参数调度对应 probe。
/// AppDelegate 只做 application bootstrap + 调用本 runner, 诊断逻辑全在此目录。
@MainActor
enum DiagnosticRunner {
    // MARK: - 模式分派

    static func run(container: DependencyContainer) {
        if let screenshotPath = screenshotArgument() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                captureScreenshot(to: screenshotPath, container: container)
            }
        } else if CommandLine.arguments.contains("--touchdebug") {
            // 触点调试: 打印引擎状态 + 原始触点帧(GESTURE_DEBUG env), 15s 后退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                print("TOUCHDEBUG status=\(container.activationCoordinator.diagnostics())")
                print("TOUCHDEBUG 请在触控板上做四指捏合, 观察 GESTURE_DEBUG 输出")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                print("TOUCHDEBUG done")
                NSApp.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--touchwatch") {
            // 持续触点监听(配合 GESTURE_DEBUG 日志), 手动终止
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                print("TOUCHWATCH status=\(container.activationCoordinator.diagnostics())")
                print("TOUCHWATCH 持续监听中, 请做四指捏合; Ctrl+C 或 kill 结束")
                fflush(stdout)
            }
        } else if CommandLine.arguments.contains("--perf") {
            runPerf(container: container)
        } else if CommandLine.arguments.contains("--pagetest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                PageTestProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                SmokeProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--iconbench") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                IconProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--searchprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                SearchProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--threefingerdiag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                ThreeFingerProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--dragcacheprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                DragProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--pagingprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PagingProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--settingsshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                SettingsShotProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--gridtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                GridProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--sourcesprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                SourcesProbe.run(container: container)
            }
        }
    }

    /// 性能基线: 10 次 show/hide 循环(真实事件循环时序)。
    private static func runPerf(container: DependencyContainer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let controller = container.windowController
            var cycle = 0
            @MainActor func next() {
                guard cycle < 10 else {
                    print("PERF done")
                    NSApp.terminate(nil)
                    return
                }
                cycle += 1
                controller.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak controller] in
                    MainActor.assumeIsolated {
                        controller?.hide()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        MainActor.assumeIsolated {
                            next()
                        }
                    }
                }
            }
            MainActor.assumeIsolated {
                next()
            }
        }
    }

    // MARK: - 共享收口

    static func finishProbe(_ name: String, ok: Bool, detail: String? = nil) -> Never {
        if let detail {
            print("\(name) \(ok ? "OK" : "FAIL") \(detail)")
        } else {
            print("\(name) \(ok ? "OK" : "FAIL")")
        }
        terminateDiagnostic(success: ok)
    }

    static func terminateDiagnostic(success: Bool) -> Never {
        fflush(stdout)
        fflush(stderr)
        exit(success ? 0 : 1)
    }

    static func diagnosticCounter(_ key: String, in diagnostics: String) -> Int? {
        for token in diagnostics.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return Int(parts[1])
        }
        return nil
    }

    static func finishSmoke(store: LauncherStore, ok: Bool = true, detail: String? = nil) -> Never {
        // 启动路径验证仅在显式 --launchtest 时真实拉起应用(避免测试副作用)
        if CommandLine.arguments.contains("--launchtest") {
            let chrome = store.displayModel().visibleAppIDs.first { $0.rawValue.contains("Chrome") }
            if let chrome {
                store.launch(chrome)
                print("SMOKE launch=OK \(chrome.rawValue)")
            } else {
                print("SMOKE launch=SKIPPED no chrome")
            }
        } else {
            print("SMOKE launch=SKIPPED (no --launchtest)")
        }

        if let detail {
            print("SMOKE \(ok ? "OK" : "FAIL") \(detail)")
        } else {
            print("SMOKE \(ok ? "OK" : "FAIL")")
        }
        terminateDiagnostic(success: ok)
    }

    // MARK: - 截图辅助

    static func screenshotArgument() -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--screenshot"),
              args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    /// 调试截图: 应用自渲染窗口内容(cacheDisplay, 无需屏幕录制权限)。
    static func captureScreenshot(to path: String, container: DependencyContainer) {
        guard let window = container.windowController.window,
              let contentView = window.contentView else { return }
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        let image = NSImage(size: contentView.bounds.size)
        image.addRepresentation(rep)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("SCREENSHOT_WRITTEN \(path)")
        NSApp.terminate(nil)
    }
}
