import Foundation
import Testing
@testable import LaunchUI

@Suite("Accessibility display observer")
@MainActor
struct AccessibilityDisplayObserverTests {
    @Test("injected provider refreshes the latest snapshot from the injected notification center")
    func injectedProviderRefreshesSnapshot() {
        let notificationCenter = NotificationCenter()
        let initial = MotionEnvironmentSnapshot(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false
        )
        let updated = MotionEnvironmentSnapshot(
            reduceMotion: true,
            reduceTransparency: true,
            increaseContrast: true
        )
        var providerReadCount = 0

        let observer = AccessibilityDisplayObserver(
            notificationCenter: notificationCenter,
            initialSnapshot: initial,
            snapshotProvider: {
                providerReadCount += 1
                return updated
            }
        )

        #expect(observer.snapshot == initial)
        #expect(providerReadCount == 0)

        observer.start()
        notificationCenter.post(
            name: MotionEnvironment.displayOptionsDidChange,
            object: nil
        )

        #expect(providerReadCount == 1)
        #expect(observer.snapshot == updated)
        #expect(observer.isRegistered)
    }

    @Test("repeated start calls do not duplicate notification refreshes")
    func repeatedStartDoesNotDuplicateRefreshes() {
        let notificationCenter = NotificationCenter()
        let initial = MotionEnvironmentSnapshot(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false
        )
        let updated = MotionEnvironmentSnapshot(
            reduceMotion: false,
            reduceTransparency: true,
            increaseContrast: false
        )
        var providerReadCount = 0

        let observer = AccessibilityDisplayObserver(
            notificationCenter: notificationCenter,
            initialSnapshot: initial,
            snapshotProvider: {
                providerReadCount += 1
                return updated
            }
        )

        observer.start()
        observer.start()
        observer.start()
        notificationCenter.post(
            name: MotionEnvironment.displayOptionsDidChange,
            object: nil
        )

        #expect(providerReadCount == 1)
        #expect(observer.snapshot == updated)
    }

    @Test("teardown is idempotent and prevents later refreshes")
    func teardownPreventsLaterRefreshes() {
        let notificationCenter = NotificationCenter()
        let initial = MotionEnvironmentSnapshot(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false
        )
        let updated = MotionEnvironmentSnapshot(
            reduceMotion: true,
            reduceTransparency: false,
            increaseContrast: false
        )
        var providerReadCount = 0

        let observer = AccessibilityDisplayObserver(
            notificationCenter: notificationCenter,
            initialSnapshot: initial,
            snapshotProvider: {
                providerReadCount += 1
                return updated
            }
        )

        observer.start()
        observer.teardown()
        observer.teardown()
        notificationCenter.post(
            name: MotionEnvironment.displayOptionsDidChange,
            object: nil
        )

        #expect(providerReadCount == 0)
        #expect(observer.snapshot == initial)
        #expect(!observer.isRegistered)

        observer.start()
        notificationCenter.post(
            name: MotionEnvironment.displayOptionsDidChange,
            object: nil
        )
        #expect(providerReadCount == 0)
        #expect(observer.snapshot == initial)
    }
}
