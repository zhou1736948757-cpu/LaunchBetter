import AppKit
import LaunchCore
import LaunchUI

/// FOLDER probe: --smoke --folders 子模式, 事务式文件夹 create/rename/add/dissolve。
@MainActor
enum FolderProbe {
    static func run(store: LauncherStore, display: DisplayModel) {
        let visible = display.flatSlots
        let apps = visible.compactMap { item -> AppID? in
            if case .app(let id) = item { return id }
            return nil
        }
        guard apps.count >= 3 else {
            DiagnosticRunner.finishSmoke(store: store, ok: false, detail: "folder probe requires at least 3 visible app slots; found \(apps.count)")
        }
        let baselineFlatSlots = visible
        guard Set(baselineFlatSlots).count == baselineFlatSlots.count else {
            DiagnosticRunner.finishSmoke(store: store, ok: false, detail: "folder probe baseline contains duplicate display items")
        }
        let baselineFolderIDs = Set(store.folderNames().keys)
        let previousOnDataChange = store.onDataChange
        var stage = 0
        var folderID: FolderID?
        var completed = false
        let stepNames = ["create", "rename", "add", "dissolve"]

        func finishFolder(_ ok: Bool, detail: String) {
            guard !completed else { return }
            completed = true
            store.onDataChange = previousOnDataChange
            print("SMOKE folderOps=\(ok ? "OK" : "FAIL") \(detail)")
            DiagnosticRunner.finishSmoke(store: store, ok: ok, detail: detail)
        }

        store.onDataChange = { [weak store] in
            previousOnDataChange?()
            guard let store, !completed else { return }
            switch stage {
            case 0: // 创建完成
                let newIDs = Set(store.folderNames().keys).subtracting(baselineFolderIDs)
                if newIDs.count > 1 {
                    finishFolder(false, detail: "create produced \(newIDs.count) new folders")
                    return
                }
                guard let id = newIDs.first else { return }
                guard store.folderNames()[id] == "冒烟文件夹",
                      store.folderChildren(id) == [apps[0], apps[1]] else { return }
                let current = store.displayModel().flatSlots
                guard current.count == baselineFlatSlots.count - 1,
                      Set(current).count == current.count,
                      current.contains(.folder(id)),
                      (store.folderChildren(id) ?? []) == [apps[0], apps[1]] else {
                    finishFolder(false, detail: "create state did not match expected folder and flat-slot count")
                    return
                }
                folderID = id
                print("SMOKE folder step=create OK")
                stage = 1
                store.renameFolder(id, to: "冒烟改名")
            case 1: // 重命名完成
                guard let id = folderID,
                      store.folderNames()[id] == "冒烟改名",
                      store.folderChildren(id) == [apps[0], apps[1]] else { return }
                print("SMOKE folder step=rename OK")
                stage = 2
                store.addToFolder(app: apps[2], folder: id)
            case 2: // 加入完成
                guard let id = folderID,
                      store.folderChildren(id) == [apps[0], apps[1], apps[2]] else { return }
                let current = store.displayModel().flatSlots
                guard current.count == baselineFlatSlots.count - 2,
                      Set(current).count == current.count,
                      !current.contains(.app(apps[2])),
                      current.contains(.folder(id)),
                      (store.folderChildren(id) ?? []) == [apps[0], apps[1], apps[2]] else {
                    finishFolder(false, detail: "add state did not contain all three folder children")
                    return
                }
                print("SMOKE folder step=add OK")
                stage = 3
                store.dissolveFolder(id)
            case 3: // 解散完成
                guard let id = folderID,
                      store.folderNames()[id] == nil,
                      store.folderChildren(id) == nil else { return }
                let current = store.displayModel().flatSlots
                guard current == baselineFlatSlots,
                      Set(current).count == current.count else {
                    finishFolder(false, detail: "dissolve state did not restore the baseline display")
                    return
                }
                print("SMOKE folder step=dissolve OK")
                finishFolder(true, detail: "all async folder steps verified")
            default:
                break
            }
        }
        store.createFolder(name: "冒烟文件夹", appIDs: [apps[0], apps[1]])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            MainActor.assumeIsolated {
                guard !completed else { return }
                let step = stepNames[min(stage, stepNames.count - 1)]
                finishFolder(false, detail: "timeout during \(step) step")
            }
        }
    }
}
