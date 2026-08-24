import AppKit
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

/// P2-A: AppCellView 懒分配 FolderThumbnailView。
///
/// 普通 App 配置不得实例化/加入文件夹缩略图层级(NSVisualEffectView +
/// container/sheen + 9 个图标 layer); 文件夹配置懒创建唯一实例; 文件夹→App
/// 复用/重配置必须真正移除并释放层级; app→folder 必须安全重建。
///
/// 几何/拖拽行为由既有 FolderThumbnailMetricsWiringTests 等覆盖, 本套件只
/// 断言层级存在性/可见性/唯一性, 不触碰私有类型耦合(经层级查找)。
@Suite("AppCellView folder thumbnail lazy allocation (P2-A)")
@MainActor
struct AppCellFolderThumbnailLazyAllocationTests {
    // MARK: - helpers

    /// 从 cell 视图树中收集 pressContainer 下的全部 NSVisualEffectView
    /// (即 FolderThumbnailView 实例; 私有类经层级查找, 不耦合类型名)。
    private func folderThumbnailViews(in cell: AppCellView) -> [NSVisualEffectView] {
        guard let pressContainer = cell.view.subviews.first else { return [] }
        return pressContainer.subviews.compactMap { $0 as? NSVisualEffectView }
    }

    /// 建一个带窗口的 cell, 保证 loadView 与布局路径被真实执行。
    private func makeCellInWindow() -> (cell: AppCellView, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let cell = AppCellView()
        window.contentView = cell.view
        window.layoutIfNeeded()
        cell.view.layoutSubtreeIfNeeded()
        return (cell, window)
    }

    private func configureApp(_ cell: AppCellView) {
        cell.configure(
            displayName: "App",
            colorIndex: 0,
            accessibilityHint: "App",
            appID: AppID("/Applications/Plain.app")!,
            pointSize: 80,
            iconProvider: nil
        )
        cell.view.layoutSubtreeIfNeeded()
    }

    private func configureFolder(_ cell: AppCellView, id: String = "folder://p2-a") {
        let children = (0..<3).map { AppID("/Applications/Child\($0).app")! }
        cell.configureFolder(
            displayName: "Folder",
            accessibilityHint: "Folder",
            folderID: FolderID(id)!,
            children: children,
            pointSize: 80,
            iconProvider: nil
        )
        cell.view.layoutSubtreeIfNeeded()
    }

    // MARK: - tests

    @Test("app 配置: 层级中无 FolderThumbnailView")
    func appConfigureHasNoFolderThumbnail() {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureApp(cell)
        #expect(folderThumbnailViews(in: cell).isEmpty)
    }

    @Test("folder 配置: 恰好一个可见 FolderThumbnailView")
    func folderConfigureCreatesOneVisibleThumbnail() {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureFolder(cell)
        let thumbnails = folderThumbnailViews(in: cell)
        #expect(thumbnails.count == 1)
        #expect(thumbnails.first?.isHidden == false)
    }

    @Test("重复 folder 配置: 复用同一实例(identity 不变), 不产生重复")
    func repeatedFolderConfigureReusesSameInstance() {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureFolder(cell, id: "folder://p2-a-repeat-1")
        let first = folderThumbnailViews(in: cell).first
        #expect(first != nil)
        configureFolder(cell, id: "folder://p2-a-repeat-2")
        let second = folderThumbnailViews(in: cell).first
        configureFolder(cell, id: "folder://p2-a-repeat-3")
        let third = folderThumbnailViews(in: cell).first
        // 层级中始终只有一个实例, 且跨重配置 identity 不变(不销毁重建)。
        #expect(folderThumbnailViews(in: cell).count == 1)
        #expect(second === first)
        #expect(third === first)
        #expect(third?.isHidden == false)
    }

    @Test("folder→app 复用: 移除并释放层级")
    func folderToAppRemovesHierarchy() {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureFolder(cell)
        #expect(folderThumbnailViews(in: cell).count == 1)
        configureApp(cell)
        #expect(folderThumbnailViews(in: cell).isEmpty)
    }

    @Test("app→folder 重建: 安全创建新实例")
    func appToFolderRecreatesSafely() {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureApp(cell)
        #expect(folderThumbnailViews(in: cell).isEmpty)
        configureFolder(cell)
        let thumbnails = folderThumbnailViews(in: cell)
        #expect(thumbnails.count == 1)
        #expect(thumbnails.first?.isHidden == false)
    }

    @Test("App→Folder→App: folder 配置创建, app 配置释放, 再 folder 重建新实例")
    func appFolderAppSequenceReleasesAndRecreates() {
        let (cell, window) = makeCellInWindow()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        configureApp(cell)
        #expect(folderThumbnailViews(in: cell).isEmpty)

        configureFolder(cell, id: "folder://p2-a-seq-1")
        let first = folderThumbnailViews(in: cell).first
        #expect(first != nil)

        // folder→app: 显式释放并移除层级。
        configureApp(cell)
        #expect(folderThumbnailViews(in: cell).isEmpty)

        // app→folder: 因已释放, 重建为新实例(identity 不同)。
        configureFolder(cell, id: "folder://p2-a-seq-2")
        let second = folderThumbnailViews(in: cell).first
        #expect(second != nil)
        #expect(second !== first)
        #expect(second?.isHidden == false)
    }
}
