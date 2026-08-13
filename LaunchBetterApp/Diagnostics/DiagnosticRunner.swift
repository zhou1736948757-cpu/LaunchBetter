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
        if let shot = libraryShotArgument() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                AppLibraryShotProbe.run(
                    container: container,
                    outputPath: shot.path,
                    state: shot.state
                )
            }
        } else if let screenshotPath = screenshotArgument() {
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
        } else if CommandLine.arguments.contains("--pagingeventtrace") {
            // PA4: 逐事件 trace(写 /tmp/lb-paging-eventtrace.log; PagingTraceLog
            // 开关在 GridViewController.setupPagingController 经 flag 联动开启)。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PagingEventTraceProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--pagecompositor") {
            // P2: Page Compositor 实验(默认关; flag 开启组合器 + 遥测, A/B 对比)。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PageCompositorProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--libraryblanktrace") {
            // V1: Library 空白点击逐会话 trace(写 /tmp/lb-library-blank-trace.log;
            // 视图侧开关在 AppLibraryViewController.loadView 经 flag 联动开启)。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                LibraryBlankTraceProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--pagingstressprobe") {
            // PA4: Library↔Page1 500 轮压力探针(不变式断言)。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PagingStressProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--pagingscrollprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PagingScrollProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--layoutdiag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                LayoutProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--hotcornerdiag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                HotCornerProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--settingsshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                SettingsShotProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--gridtest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                GridProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--settingsownershipprobe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                SettingsOwnershipProbe.run(container: container)
            }
        } else if CommandLine.arguments.contains("--showstay") {
            // 保持启动器显示(供外部 screencapture 截真实屏幕, 含 NSSearchField)。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if CommandLine.arguments.contains("--search-mode") {
                    container.store.searchQuery = "com"
                }
                container.windowController.show()
                if CommandLine.arguments.contains("--search-mode") {
                    container.windowController.refreshGrid()
                }
                if CommandLine.arguments.contains("--settings") {
                    container.windowController.openSettingsFromMenu()
                    print("SHOWSTAY settings=open")
                }
                NSApp.activate(ignoringOtherApps: true)
                container.windowController.window?.orderFrontRegardless()
                container.windowController.window?.makeKeyAndOrderFront(nil)
                container.windowController.window?.displayIfNeeded()
                if CommandLine.arguments.contains("--folder-mode") {
                    let opened = container.windowController.openFirstFolderForDiagnostic()
                    print("SHOWSTAY folder=\(opened)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        container.windowController.diagnosticFolderStartTitleEdit()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            let state = container.windowController.diagnosticFolderTitleEditState()
                            print("SHOWSTAY titleEdit=\(state)")
                            fflush(stdout)
                        }
                    }
                }
                if CommandLine.arguments.contains("--hover-settings") {
                    container.windowController.movePointerToSettingsButtonForDiagnostic()
                }
                print("SHOWSTAY visible=\(container.windowController.isActuallyVisible)")
                fflush(stdout)
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

    /// E10: `--libraryshot <output.png>` + 可选 `--library-state top|mid|detail|search|settings`。
    static func libraryShotArgument() -> (path: String, state: String)? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--libraryshot"),
              args.indices.contains(index + 1) else {
            return nil
        }
        var state = "top"
        if let stateIndex = args.firstIndex(of: "--library-state"),
           args.indices.contains(stateIndex + 1) {
            state = args[stateIndex + 1]
        }
        return (args[index + 1], state)
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
