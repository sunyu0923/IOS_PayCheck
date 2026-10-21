import Combine
import Foundation
import WatchConnectivity

@MainActor final class WatchSnapshotStore: NSObject, ObservableObject {
    @Published private var persistence: WatchSnapshotPersistence
    @Published private(set) var status = "Waiting for iPhone"
    @Published private(set) var isCached = false

    var state: WatchSnapshotState { persistence.state }

    private let session: WCSession?
    private var started = false

    override convenience init() { self.init(defaults: .standard) }

    init(defaults: UserDefaults) {
        persistence = WatchSnapshotPersistence(defaults: defaults, now: Date())
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        isCached = state.latest != nil
        if state.isLocallyBlocked {
            status = "Hidden on this watch"
        } else if isCached {
            status = state.latest?.isCleared == true ? "No shared data · cached" : "Saved on this watch"
        }
    }

    /// Immediate, offline Watch consent control; never sends a command to iPhone.
    func clearAndHide() {
        do {
            try persistence.setLocallyBlocked(true)
            // Capture any context not yet delivered to the delegate as a barrier too.
            if let session { receiveContext(session.receivedApplicationContext) }
            isCached = false
            status = "Hidden on this watch"
        } catch {
            status = "Hidden · could not save preference"
        }
    }

    /// Only this explicit Watch action lifts the local block. Consume the current
    /// application context WHILE blocked, so enabling cannot redisplay that packet.
    func showNewPhoneUpdates() {
        guard state.isLocallyBlocked else { return }
        if let session { receiveContext(session.receivedApplicationContext) }
        do {
            try persistence.setLocallyBlocked(false)
            status = "Waiting for a new iPhone update"
        } catch {
            status = "Could not enable updates"
        }
    }

    func start() {
        guard let session else { status = "Connectivity unavailable"; return }
        if !started {
            started = true
            session.delegate = self
        }
        if session.activationState == .activated {
            receiveContext(session.receivedApplicationContext)
        } else if session.activationState == .notActivated {
            session.activate()
        }
    }

    private func receiveContext(_ context: [String: Any]) {
        if context.isEmpty { return }
        guard context.count == 1, let data = context[WatchSnapshot.contextKey] as? Data else {
            status = "Update rejected · open iPhone"
            return
        }
        receive(data)
    }

    private func receive(_ data: Data) {
        do {
            guard try persistence.receive(data, now: Date()) else { return }
            isCached = false
            if state.isLocallyBlocked {
                status = "Hidden on this watch"
            } else {
                status = state.latest?.isCleared == true ? "Sharing turned off" : "Received from iPhone"
            }
        } catch {
            // Incoming invalid data was never cached. Keep the last VALID cache,
            // especially a tombstone, so a relaunch cannot resurrect older state.
            // Invalid/unsupported cached data itself is purged during initialization.
            status = "Update rejected · open iPhone"
        }
    }
}

extension WatchSnapshotStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let failed = error != nil || activationState != .activated
        Task { @MainActor [weak self] in
            guard let self else { return }
            if failed { self.status = "Connection failed · open iPhone" }
            else { self.start() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // Extract only Sendable Data before crossing to the main actor.
        let data = applicationContext.count == 1 ? applicationContext[WatchSnapshot.contextKey] as? Data : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let data else { self.status = "Update rejected · open iPhone"; return }
            self.receive(data)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.start() }
    }
}
