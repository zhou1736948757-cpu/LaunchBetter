# 任务包: Stage E7 Store / metadata / Library model wiring

## 背景

当前已存在并通过测试:

- `LaunchCore.AppLibraryModelBuilder` / `AppLibraryMetadataSnapshot`
- `LaunchPlatform.AppLibraryMetadataStore`
- 独立 `AppLibraryViewController`，通过 model/displayName/iconProvider/onLaunch 注入
- `LauncherSurface` 和 leading layout geometry

现在将 derived Library model 接入真实 Launcher 数据流，但暂不修改 GridViewController 的外层分页。

## 允许修改的文件

- `LaunchBetterApp/LauncherStore.swift`
- `LaunchBetterApp/DependencyContainer.swift`
- `Packages/LaunchUI/Sources/LaunchUI/LauncherStoring.swift`

可新增最小测试/探针文件，仅限:

- `Packages/LaunchBetter/Tests/??` 不存在，禁止新建错误路径
- 如无法低风险写 Store 集成测试，依赖 Core/Platform 已有测试并在报告中明确，禁止扩大范围

禁止修改其它生产文件、禁止提交、禁止切换分支、禁止修改旧仓库或现有未跟踪文件。

## 接口要求

在 LaunchUI 定义独立只读能力，避免给所有测试 fake 的 `LauncherStoring` 增加必需方法:

```swift
@MainActor
public protocol AppLibraryDataProviding: AnyObject {
    func appLibraryModel() -> AppLibraryModel
}
```

`LauncherStore` 实现该 protocol；不要把 AppLibrary model 写进 LayoutStore 或让 LaunchUI 依赖 LaunchPlatform。

## Store 语义

- Store 持有 `AppLibraryMetadataStore`、当前 metadata snapshot 和 memory-only `AppLibraryModel` cache。
- 初始化使用 DependencyContainer 从 Application Support 读取的 initial metadata seed；这属于启动恢复，不是 show/Library entry IO。
- 首帧先用 initial Catalog/Layout/Config 构建 model；model build 必须纯内存。
- bootstrap 在后台 actor 生命周期中执行：当前已有 Catalog apps 作为 baseline，`AppLibraryMetadataStore.bootstrap`；不得把存量 apps 生成 Recently Added。
- FSEvents/catalog snapshot 成功提交后调用 `recordDiscovered`，刷新 catalog index、Layout reconcile、search index 和 Library model；陈旧 generation 不得覆盖新 model。
- `save(_:)` 的 language/custom name/hidden/config 变化同步重建 Library model；不扫磁盘、不重建 Layout。
- `launch(_:)` 是唯一 usage 记录入口：只有 `NSWorkspace.shared.open(record.url)` 返回 true 才异步 `recordLaunch`，不等待写盘、不阻塞启动；metadata 返回后更新 cache/notify。不要在 Library UI 另记一次。
- 当前 Library session 的冻结由 ViewController 负责，Store 只提供最新 model。
- custom source App 只要在 Catalog 就进入 builder；hidden/missing 由 builder 过滤。
- `show()` 仍默认 Page 1，Store 不持久化 last surface。

## 约束

- 不修改 AppRecord/Catalog/metadata actor 的已验证 API。
- `LauncherStore` 初始化必须先完成所有 stored properties，再调用 instance method。
- 保持 `show = 0 scan / 0 Info.plist IO / 0 icon rescan`。
- 不增加全局单例、`DispatchQueue.main.sync` 或 per-frame Store state。
- `notifyDataChange` 仍保持现有主网格 onDataChange 与 dataObservers 语义。
- 外部 async metadata/catalog 结果需要 owner/generation 或当前 Store 生命周期校验。

## 验收

- `cd Packages/LaunchCore && swift test` 通过。
- `cd Packages/LaunchPlatform && swift test` 通过。
- `cd Packages/LaunchUI && swift test` 通过。
- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- `grep`/源码审计确认没有 `DispatchQueue.main.sync` 新增，没有 LayoutStore usage 字段。
- 返回改动文件、数据流、启动/launch 成功语义、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
