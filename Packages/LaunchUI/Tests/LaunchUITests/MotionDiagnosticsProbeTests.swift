import Testing
@testable import LaunchUI

@Suite("Motion diagnostics probe")
struct MotionDiagnosticsProbeTests {
    @Test("lifecycle report is deterministic and latest intent wins")
    func deterministicLifecycleReport() {
        let environment = MotionEnvironmentSnapshot(
            reduceMotion: true,
            reduceTransparency: false,
            increaseContrast: true
        )

        let first = MotionDiagnosticsProbe.evaluate(environment: environment)
        let second = MotionDiagnosticsProbe.evaluate(environment: environment)

        #expect(first == second)
        #expect(first.isSuccessful)
        #expect(first.launcher.finalState == "visible")
        #expect(first.launcher.finalVisible)
        #expect(first.folder.completionCalls == 1)
        #expect(first.folder.proxyTeardown)
        #expect(first.folder.sourceOwnerRestored)
        #expect(first.settings.finalState == "visible")
        #expect(first.settings.completionOnce)
    }

    @Test("environment and lifecycle counters are emitted through the sink")
    func injectedReportOutput() {
        let environment = MotionEnvironmentSnapshot(
            reduceMotion: false,
            reduceTransparency: true,
            increaseContrast: false
        )
        var lines: [String] = []

        let ok = MotionDiagnosticsProbe.run(
            environment: environment,
            output: { lines.append($0) }
        )

        #expect(ok)
        #expect(lines.first == "MOTIONPROBE environment reduceMotion=false reduceTransparency=true increaseContrast=false")
        #expect(lines.contains { $0.contains("starts=") && $0.contains("staleRejected=") && $0.contains("settleSteps=") })
        #expect(lines.contains { $0.contains("folder") && $0.contains("coordinator=not-invoked") })
    }
}
