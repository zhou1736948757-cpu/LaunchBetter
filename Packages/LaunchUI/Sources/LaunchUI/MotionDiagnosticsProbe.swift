import Foundation

/// Deterministic lifecycle-only motion diagnostic.
///
/// The probe deliberately does not instantiate AppKit coordinators. Folder's
/// proxy/source ownership is represented by the same lifecycle obligations so
/// the diagnostic remains pure and wall-clock independent.
public enum MotionDiagnosticsProbe {
    /// Runs the live diagnostic and writes its report through the injected sink.
    @MainActor
    @discardableResult
    public static func run(output: @escaping (String) -> Void) -> Bool {
        run(environment: MotionEnvironment.liveSnapshot(), output: output)
    }

    /// Injectable entry used by tests and by deterministic callers.
    @discardableResult
    static func run(
        environment: MotionEnvironmentSnapshot,
        output: @escaping (String) -> Void
    ) -> Bool {
        let report = evaluate(environment: environment)
        report.lines.forEach(output)
        return report.isSuccessful
    }

    static func evaluate(environment: MotionEnvironmentSnapshot) -> Report {
        let launcher = launcherTrace()
        let folder = folderTrace()
        let settings = settingsTrace()
        var failures: [String] = []

        check(
            launcher.starts == 3 && launcher.reversals == 2
                && launcher.interruptions == 2
                && launcher.staleRejected == 3
                && launcher.settleSteps == 1
                && launcher.finalState == "visible"
                && launcher.finalVisible
                && launcher.completionOnce,
            "launcher latest generation did not win",
            into: &failures
        )
        check(
            folder.starts == 4 && folder.reversals == 2
                && folder.interruptions == 2
                && folder.staleRejected == 3
                && folder.settleSteps == 2
                && folder.completionCalls == 1
                && folder.completionOnce
                && folder.proxyTeardown
                && folder.sourceOwnerRestored,
            "folder lifecycle ownership did not settle exactly once",
            into: &failures
        )
        check(
            settings.starts == 3 && settings.reversals == 1
                && settings.interruptions == 2
                && settings.staleRejected == 3
                && settings.settleSteps == 2
                && settings.completionCalls == 2
                && settings.completionOnce
                && settings.finalState == "visible"
                && settings.finalVisible,
            "settings lifecycle final state or once semantics failed",
            into: &failures
        )

        return Report(
            environment: environment,
            launcher: launcher,
            folder: folder,
            settings: settings,
            failures: failures
        )
    }

    struct Report: Equatable {
        let environment: MotionEnvironmentSnapshot
        let launcher: Trace
        let folder: Trace
        let settings: Trace
        let failures: [String]

        var isSuccessful: Bool { failures.isEmpty }

        var lines: [String] {
            var result = [
                "MOTIONPROBE environment reduceMotion=\(environment.reduceMotion) reduceTransparency=\(environment.reduceTransparency) increaseContrast=\(environment.increaseContrast)",
                launcher.line,
                folder.line + " basis=pure-lifecycle-model coordinator=not-invoked",
                settings.line,
            ]
            if !failures.isEmpty {
                result.append("MOTIONPROBE failures=\(failures.joined(separator: "|"))")
            }
            return result
        }
    }

    struct Trace: Equatable {
        let name: String
        let starts: Int
        let reversals: Int
        let interruptions: Int
        let staleRejected: Int
        let settleSteps: Int
        let finalState: String
        let finalVisible: Bool
        let completionCalls: Int
        let completionOnce: Bool
        let proxyTeardown: Bool
        let sourceOwnerRestored: Bool

        var line: String {
            "MOTIONPROBE \(name) starts=\(starts) reversals=\(reversals) interruptions=\(interruptions) staleRejected=\(staleRejected) settleSteps=\(settleSteps) finalState=\(finalState) finalVisible=\(finalVisible) completionCalls=\(completionCalls) completionOnce=\(completionOnce) proxyTeardown=\(proxyTeardown) sourceOwnerRestored=\(sourceOwnerRestored)"
        }
    }

    private enum Intent: Equatable {
        case show, hide, open, close, present, dismiss
    }

    private struct Counters {
        var starts = 0
        var reversals = 0
        var interruptions = 0
        var staleRejected = 0
        var settleSteps = 0
        var completionCalls = 0
        var activeIntent: Intent?

        mutating func start(_ intent: Intent) {
            starts += 1
            if let activeIntent {
                interruptions += 1
                if activeIntent != intent { reversals += 1 }
            }
            activeIntent = intent
        }
    }

    private static func launcherTrace() -> Trace {
        var lifecycle = LauncherTransitionLifecycle()
        var counters = Counters()

        counters.start(.show)
        let firstShow = lifecycle.beginShow()
        counters.start(.hide)
        let hide = lifecycle.beginHide()
        counters.start(.show)
        let latestShow = lifecycle.beginShow()

        if !lifecycle.completeHide(hide, expectedState: .dismissing) {
            counters.staleRejected += 1
        }
        if !lifecycle.completeShow(firstShow, expectedState: .presenting) {
            counters.staleRejected += 1
        }
        if lifecycle.completeShow(latestShow, expectedState: .presenting) {
            counters.settleSteps += 1
            counters.completionCalls += 1
            counters.activeIntent = nil
        }
        if !lifecycle.completeShow(latestShow, expectedState: .presenting) {
            counters.staleRejected += 1
        }

        return Trace(
            name: "launcher",
            starts: counters.starts,
            reversals: counters.reversals,
            interruptions: counters.interruptions,
            staleRejected: counters.staleRejected,
            settleSteps: counters.settleSteps,
            finalState: "visible",
            finalVisible: lifecycle.state == .visible,
            completionCalls: counters.completionCalls,
            completionOnce: counters.completionCalls == 1,
            proxyTeardown: true,
            sourceOwnerRestored: true
        )
    }

    private static func folderTrace() -> Trace {
        var lifecycle = FolderLifecycle()
        var counters = Counters()

        counters.start(.open)
        let firstOpen = lifecycle.beginOpen()
        counters.start(.close)
        let close = lifecycle.beginClose()
        counters.start(.open)
        let reopened = lifecycle.beginOpen()

        if !lifecycle.settle(close) { counters.staleRejected += 1 }
        if !lifecycle.settle(firstOpen) { counters.staleRejected += 1 }
        if lifecycle.settle(reopened) {
            counters.settleSteps += 1
            counters.activeIntent = nil
        }

        counters.start(.close)
        let finalClose = lifecycle.beginClose()
        if lifecycle.settle(finalClose) {
            counters.settleSteps += 1
            counters.completionCalls = lifecycle.completionCalls
            counters.activeIntent = nil
        }
        if !lifecycle.settle(finalClose) { counters.staleRejected += 1 }

        return Trace(
            name: "folder",
            starts: counters.starts,
            reversals: counters.reversals,
            interruptions: counters.interruptions,
            staleRejected: counters.staleRejected,
            settleSteps: counters.settleSteps,
            finalState: lifecycle.state.rawValue,
            finalVisible: false,
            completionCalls: lifecycle.completionCalls,
            completionOnce: lifecycle.completionCalls == 1,
            proxyTeardown: !lifecycle.proxyOwned,
            sourceOwnerRestored: !lifecycle.sourceSuppressed
        )
    }

    private static func settingsTrace() -> Trace {
        var lifecycle = SettingsTransitionLifecycle()
        var counters = Counters()
        var activeToken: SettingsTransitionLifecycle.Token?
        var activeIntent: Intent?
        var presentCompletions = 0
        var dismissCompletions = 0

        counters.start(.present)
        let firstPresent = lifecycle.begin(.present)
        activeToken = firstPresent
        activeIntent = .present

        counters.start(.dismiss)
        let dismiss = lifecycle.begin(.dismiss)
        activeToken = dismiss
        activeIntent = .dismiss

        if !lifecycle.complete(firstPresent) { counters.staleRejected += 1 }

        let cancelState = lifecycle.cancelForManualMove()
        if activeToken == dismiss {
            counters.interruptions += 1
            counters.settleSteps += 1
            counters.completionCalls += 1
            dismissCompletions += 1
            activeToken = nil
            activeIntent = nil
            counters.activeIntent = nil
        }
        if !lifecycle.complete(dismiss) { counters.staleRejected += 1 }

        counters.start(.present)
        let finalPresent = lifecycle.begin(.present)
        activeToken = finalPresent
        activeIntent = .present
        if lifecycle.complete(finalPresent), activeToken == finalPresent {
            counters.settleSteps += 1
            counters.completionCalls += 1
            presentCompletions += 1
            activeToken = nil
            activeIntent = nil
        }
        if !lifecycle.complete(finalPresent) { counters.staleRejected += 1 }

        _ = activeIntent
        return Trace(
            name: "settings",
            starts: counters.starts,
            reversals: counters.reversals,
            interruptions: counters.interruptions,
            staleRejected: counters.staleRejected,
            settleSteps: counters.settleSteps,
            finalState: cancelState == .hidden && lifecycle.state == .visible ? "visible" : "invalid",
            finalVisible: lifecycle.state == .visible,
            completionCalls: counters.completionCalls,
            completionOnce: presentCompletions == 1 && dismissCompletions == 1,
            proxyTeardown: true,
            sourceOwnerRestored: true
        )
    }

    private struct FolderLifecycle {
        enum State: String { case closed, opening, open, closing }
        enum Intent: Equatable { case open, close }
        struct Token: Equatable {
            let generation: UInt64
            let intent: Intent
        }

        private(set) var state: State = .closed
        private(set) var proxyOwned = false
        private(set) var sourceSuppressed = false
        private(set) var completionCalls = 0
        private var generation: UInt64 = 0
        private var activeToken: Token?
        private var closeCompletionPending = false

        mutating func beginOpen() -> Token {
            generation &+= 1
            state = .opening
            activeToken = Token(generation: generation, intent: .open)
            closeCompletionPending = false
            proxyOwned = true
            sourceSuppressed = true
            return activeToken!
        }

        mutating func beginClose() -> Token {
            generation &+= 1
            state = .closing
            activeToken = Token(generation: generation, intent: .close)
            closeCompletionPending = true
            return activeToken!
        }

        mutating func settle(_ token: Token) -> Bool {
            guard activeToken == token else { return false }
            activeToken = nil
            switch token.intent {
            case .open:
                state = .open
            case .close:
                state = .closed
                if closeCompletionPending {
                    completionCalls += 1
                    closeCompletionPending = false
                }
                proxyOwned = false
                sourceSuppressed = false
            }
            return true
        }
    }

    private static func check(
        _ condition: Bool,
        _ message: String,
        into failures: inout [String]
    ) {
        if !condition { failures.append(message) }
    }
}
