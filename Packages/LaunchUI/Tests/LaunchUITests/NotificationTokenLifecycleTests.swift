import Foundation
import Testing
@testable import LaunchUI

@MainActor
private final class NotificationCount {
    var value = 0
}

@Suite("Controller notification token lifecycle")
@MainActor
struct NotificationTokenLifecycleTests {
    @Test("a registered token receives notifications")
    func registeredTokenReceivesNotification() {
        let center = NotificationCenter()
        let registry = NotificationTokenRegistry(notificationCenter: center)
        let count = NotificationCount()
        let name = Notification.Name("LaunchUI.NotificationTokenLifecycle.registered")

        registry.append(center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                count.value += 1
            }
        })

        center.post(name: name, object: nil)

        #expect(count.value == 1)
        #expect(registry.count == 1)
    }

    @Test("teardown removes tokens and is safe to repeat")
    func teardownIsIdempotent() {
        let center = NotificationCenter()
        let registry = NotificationTokenRegistry(notificationCenter: center)
        let count = NotificationCount()
        let name = Notification.Name("LaunchUI.NotificationTokenLifecycle.teardown")

        registry.append(center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                count.value += 1
            }
        })

        registry.teardown()
        registry.teardown()
        center.post(name: name, object: nil)

        #expect(count.value == 0)
        #expect(registry.isEmpty)
    }

    @Test("Settings close and re-present can register a fresh token")
    func settingsCloseAndRePresentRegistersAgain() {
        let center = NotificationCenter()
        let registry = NotificationTokenRegistry(notificationCenter: center)
        let count = NotificationCount()
        let name = Notification.Name("LaunchUI.NotificationTokenLifecycle.settings")

        func registerSettingsObserver() {
            registry.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    count.value += 1
                }
            })
        }

        registerSettingsObserver()
        center.post(name: name, object: nil)
        registry.teardown()
        registerSettingsObserver()
        center.post(name: name, object: nil)

        #expect(count.value == 2)
        #expect(registry.count == 1)
    }

    @Test("Launcher hide/orderOut leaves its token registered")
    func launcherHideDoesNotTeardownObserver() {
        let center = NotificationCenter()
        let registry = NotificationTokenRegistry(notificationCenter: center)
        let count = NotificationCount()
        let name = Notification.Name("LaunchUI.NotificationTokenLifecycle.launcher")

        registry.append(center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                count.value += 1
            }
        })

        // Launcher hide/orderOut intentionally does not call teardown.
        center.post(name: name, object: nil)
        #expect(count.value == 1)
        #expect(registry.count == 1)

        registry.teardown()
        center.post(name: name, object: nil)
        #expect(count.value == 1)
    }
}
