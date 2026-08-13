import Testing
@testable import LaunchUI

@Suite("App Library interaction ownership", .serialized)
struct AppLibraryInteractionOwnershipTests {
    @Test("Library and category detail are distinct owners and Sendable")
    func libraryOwnersAreDistinct() async {
        let library = LauncherInteractionSurface.appLibrary
        let category = LauncherInteractionSurface.appLibraryCategory
        #expect(library != category)
        #expect(library != .launcher)
        #expect(category != .settings)

        let roundTrip = await Task.detached {
            (library, category)
        }.value
        #expect(roundTrip.0 == .appLibrary)
        #expect(roundTrip.1 == .appLibraryCategory)
    }

    @Test("Settings presentation route installs ownership from Library surfaces")
    func settingsRoutePreservesOwnershipSetup() {
        #expect(SettingsPresentationRoute.make(for: .launcher) == .installOwnership)
        #expect(SettingsPresentationRoute.make(for: .appLibrary) == .installOwnership)
        #expect(SettingsPresentationRoute.make(for: .appLibraryCategory) == .installOwnership)
        #expect(SettingsPresentationRoute.make(for: .folder) == .installOwnership)
        #expect(SettingsPresentationRoute.make(for: .settings) == .rePresentCurrent)
    }

    @Test("Settings ownership gate waits for the complete mouse sequence")
    func settingsGateConsumesSequenceBeforeRelease() throws {
        var gate = SettingsOwnershipGate()
        gate.beginSession()
        gate.beginConsumingSequence()

        let token = gate.receiveCloseCallback()
        #expect(token != nil)
        guard let token else { return }
        #expect(gate.acceptsFallback(token))
        #expect(!gate.canRelease())

        gate.consumeSequence()
        #expect(gate.canRelease())
        let finished = gate.finishSession()
        #expect(finished)
        #expect(!gate.acceptsFallback(token))
    }

    @Test("stale Settings fallback cannot release a newer session")
    func staleFallbackIsRejected() throws {
        var gate = SettingsOwnershipGate()
        gate.beginSession()
        gate.beginConsumingSequence()
        let stale = gate.receiveCloseCallback()
        #expect(stale != nil)
        guard let stale else { return }
        gate.consumeSequence()
        let finished = gate.finishSession()
        #expect(finished)

        gate.beginSession()
        gate.beginConsumingSequence()
        _ = gate.receiveCloseCallback()
        #expect(!gate.acceptsFallback(stale))
    }
}
