import AppKit

/// Main-thread owner for the live accessibility display-options snapshot.
///
/// The owner calls `start()` once during its lifecycle and `teardown()` when
/// that lifecycle ends. Calling `start()` repeatedly is a no-op, and an
/// observer cannot be registered again after teardown. The notification only
/// refreshes `snapshot`; it never starts, retargets, or restarts an animation.
/// A future transition/view owner should read `snapshot` when beginning its
/// transition and own this observer's start/teardown lifecycle.
@MainActor
final class AccessibilityDisplayObserver {
    typealias SnapshotProvider = @MainActor () -> MotionEnvironmentSnapshot

    private let notificationCenter: NotificationCenter
    private let notificationName: Notification.Name
    private let snapshotProvider: SnapshotProvider
    private var observation: NSObjectProtocol?
    private var didStart = false

    private(set) var snapshot: MotionEnvironmentSnapshot

    init(
        notificationCenter: NotificationCenter = .default,
        notificationName: Notification.Name = MotionEnvironment.displayOptionsDidChange,
        initialSnapshot: MotionEnvironmentSnapshot? = nil,
        snapshotProvider: @escaping SnapshotProvider = MotionEnvironment.liveSnapshot
    ) {
        self.notificationCenter = notificationCenter
        self.notificationName = notificationName
        self.snapshotProvider = snapshotProvider
        snapshot = initialSnapshot ?? snapshotProvider()
    }

    var isRegistered: Bool {
        observation != nil
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        observation = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.refreshSnapshot()
            }
        }
    }

    func teardown() {
        guard let observation else { return }
        notificationCenter.removeObserver(observation)
        self.observation = nil
    }

    private func refreshSnapshot() {
        snapshot = snapshotProvider()
    }
}
