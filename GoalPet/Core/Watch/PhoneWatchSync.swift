// Opt-in, latest-state phone publisher. No HealthKit, app model or reward dependencies.
import Combine
import Foundation
import WatchConnectivity

/// Offline-testable publisher ordering. A relaunch always starts a new UUID/epoch,
/// so revisions need not survive a process: the persisted epoch prevents reuse.
/// Reuse the v1 watermark key to advance past packets from the previous publisher.
struct WatchSnapshotSequence {
    static let watermarkKey = "goalpet.watch.watermark.v1"
    private let defaults: UserDefaults
    private var sessionID = UUID()
    private var sessionStartedAt: Date?
    private var revision: Int64 = 0

    init(defaults: UserDefaults) { self.defaults = defaults }

    mutating func beginSession() {
        sessionID = UUID()
        sessionStartedAt = nil
        revision = 0
    }

    mutating func makeSnapshot(tasks: [WatchTaskSnapshot] = [], experience: Int = 0,
                              petIDs: [String] = [], cleared: Bool, now: Date) throws -> WatchSnapshot {
        let wallTime = now.timeIntervalSince1970
        guard wallTime.isFinite, (0...WatchSnapshot.maximumTimestamp).contains(wallTime),
              revision < WatchSnapshot.maximumRevision else { throw WatchSnapshotError.invalidValue }
        let start: Date
        if let sessionStartedAt {
            start = sessionStartedAt
        } else {
            // Fail closed on corruption/exhaustion: resetting the high watermark
            // would reuse an epoch and permit retired sessions to return.
            let saved = defaults.object(forKey: Self.watermarkKey)
            guard saved == nil || saved is NSNumber else { throw WatchSnapshotError.invalidValue }
            let watermark = defaults.double(forKey: Self.watermarkKey)
            guard watermark.isFinite, (0...WatchSnapshot.maximumTimestamp).contains(watermark) else {
                throw WatchSnapshotError.invalidValue
            }
            let epoch = max(wallTime, watermark + 0.001)
            guard epoch > watermark, epoch <= WatchSnapshot.maximumTimestamp else {
                throw WatchSnapshotError.invalidValue
            }
            start = Date(timeIntervalSince1970: epoch)
        }
        let snapshot = WatchSnapshot(sessionID: sessionID, sessionStartedAt: start,
            revision: revision + 1, generatedAt: now, isCleared: cleared,
            tasks: tasks, experience: experience, petIDs: petIDs)
        _ = try snapshot.encoded()
        // Commit ordering only for a valid snapshot, before it can be transported.
        defaults.set(start.timeIntervalSince1970, forKey: Self.watermarkKey)
        sessionStartedAt = start
        revision += 1
        return snapshot
    }
}

@MainActor final class PhoneWatchSync: NSObject, ObservableObject {
    enum Status: Equatable {
        case disabled, unsupported, activating, notPaired, watchNotInstalled
        case waitingForSnapshot, queued, retryNeeded, invalidSnapshot
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: Status = .disabled

    private static let enabledKey = "goalpet.watch.enabled.v1"
    private let defaults: UserDefaults
    private let session: WCSession?
    private var started = false
    private var pending: Data?
    private var sequence: WatchSnapshotSequence

    override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey) // Absent means off.
        sequence = WatchSnapshotSequence(defaults: defaults)
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    /// Retain one instance for the app lifetime. Call on launch AND scene activation.
    /// Repeated calls retry the latest context; they never request HealthKit access.
    func start() {
        if !started {
            started = true
            session?.delegate = self
            if !isEnabled { queueClear() }
        }
        flush()
    }

    /// Call only from an explicit phone consent control. Turning off immediately
    /// replaces any pending payload and queues a tombstone, even when unreachable.
    func setEnabled(_ enabled: Bool) {
        if enabled != isEnabled {
            isEnabled = enabled
            defaults.set(enabled, forKey: Self.enabledKey)
            sequence.beginSession()
            // Keep a pending clear when opting back in until fresh data is published.
            if !enabled { queueClear() }
        } else if !enabled && pending == nil {
            queueClear()
        }
        start()
    }

    /// Map ONLY GoalEngine daily tasks, confirmed total XP and catalog pet IDs.
    /// No raw model serialization. Invalid input is rejected, not truncated/clamped.
    /// `now` is the evaluation date, normally Date(); publishing while off is ignored.
    func publish(tasks: [WatchTaskSnapshot], experience: Int, petIDs: [String], now: Date) {
        guard isEnabled else { return }
        do {
            pending = try sequence.makeSnapshot(tasks: tasks, experience: experience, petIDs: petIDs,
                                                cleared: false, now: now).encoded()
        } catch {
            status = .invalidSnapshot
            return
        }
        start()
    }

    private func queueClear() {
        // Drop the previous in-memory payload even if construction ever fails.
        pending = nil
        do {
            pending = try sequence.makeSnapshot(cleared: true, now: Date()).encoded()
        } catch {
            status = .invalidSnapshot
        }
    }

    private func flush() {
        guard let session else { status = .unsupported; return }
        guard session.activationState == .activated else {
            status = .activating
            if session.activationState == .notActivated { session.activate() }
            return
        }
        guard session.isPaired else { status = .notPaired; return }
        guard session.isWatchAppInstalled else { status = .watchNotInstalled; return }
        guard let pending else {
            status = isEnabled ? .waitingForSnapshot : .disabled
            return
        }
        do {
            // Do NOT gate this on isReachable. WCSession queues the latest context
            // for disconnected watches; there is no sendMessage/command channel.
            try session.updateApplicationContext([WatchSnapshot.contextKey: pending])
            status = isEnabled ? .queued : .disabled
        } catch {
            status = .retryNeeded // Retain latest only; retry on the next lifecycle event.
        }
    }
}

extension PhoneWatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let failed = error != nil || activationState != .activated
        Task { @MainActor [weak self] in
            guard let self else { return }
            if failed { self.status = .retryNeeded } else { self.flush() }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.status = .activating }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required for switching paired watches. The latest pending context is kept.
        Task { @MainActor [weak self] in self?.session?.activate() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.flush() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.flush() }
    }
}
