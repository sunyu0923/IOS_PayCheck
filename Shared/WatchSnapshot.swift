// Foundation-only wire contract, compiled into the phone and watch targets.
// Never add health samples, amounts, food, photos, profile/member data or commands.
import Foundation

enum WatchSnapshotError: Error, Equatable {
    case tooLarge, unsupportedVersion, invalidFields, invalidValue
}

private struct WatchWireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireWatchKeys(_ decoder: Decoder, _ expected: [String]) throws {
    let container = try decoder.container(keyedBy: WatchWireKey.self)
    guard Set(container.allKeys.map(\.stringValue)) == Set(expected) else {
        throw WatchSnapshotError.invalidFields
    }
}

struct WatchTaskSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let isComplete: Bool

    /// Supply only app-owned GoalEngine task labels, never user-entered notes or measurements.
    init(id: String, title: String, isComplete: Bool) {
        self.id = id
        self.title = title
        self.isComplete = isComplete
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, title, isComplete }

    init(from decoder: Decoder) throws {
        try requireWatchKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        isComplete = try values.decode(Bool.self, forKey: .isComplete)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(isComplete, forKey: .isComplete)
    }

    fileprivate func validate() throws {
        guard WatchSnapshot.validID(id), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 160,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WatchSnapshotError.invalidValue
        }
    }
}

struct WatchSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let contextKey = "goalpet.snapshot"
    static let maximumBytes = 32 * 1_024
    static let maximumTasks = 32
    static let maximumPets = 64
    static let maximumExperience = 1_000_000_000
    static let maximumRevision: Int64 = 9_007_199_254_740_991
    static let maximumTimestamp: TimeInterval = 4_102_444_800
    static let futureTolerance: TimeInterval = 300

    let version: Int
    let sessionID: UUID
    /// Bounded logical ordering epoch, NOT a freshness/display timestamp.
    let sessionStartedAt: Date
    let revision: Int64
    let generatedAt: Date
    let isCleared: Bool
    let tasks: [WatchTaskSnapshot]
    let experience: Int
    let petIDs: [String]

    init(sessionID: UUID, sessionStartedAt: Date, revision: Int64, generatedAt: Date,
         isCleared: Bool = false, tasks: [WatchTaskSnapshot] = [],
         experience: Int = 0, petIDs: [String] = []) {
        version = Self.currentVersion
        self.sessionID = sessionID
        self.sessionStartedAt = sessionStartedAt
        self.revision = revision
        self.generatedAt = generatedAt
        self.isCleared = isCleared
        self.tasks = tasks
        self.experience = experience
        self.petIDs = petIDs
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, sessionID, sessionStartedAt, revision, generatedAt, isCleared
        case tasks, experience, petIDs
    }

    init(from decoder: Decoder) throws {
        try requireWatchKeys(decoder, CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw WatchSnapshotError.unsupportedVersion }
        sessionID = try values.decode(UUID.self, forKey: .sessionID)
        sessionStartedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .sessionStartedAt))
        revision = try values.decode(Int64.self, forKey: .revision)
        generatedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .generatedAt))
        isCleared = try values.decode(Bool.self, forKey: .isCleared)
        tasks = try values.decode([WatchTaskSnapshot].self, forKey: .tasks)
        experience = try values.decode(Int.self, forKey: .experience)
        petIDs = try values.decode([String].self, forKey: .petIDs)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(sessionStartedAt.timeIntervalSince1970, forKey: .sessionStartedAt)
        try values.encode(revision, forKey: .revision)
        try values.encode(generatedAt.timeIntervalSince1970, forKey: .generatedAt)
        try values.encode(isCleared, forKey: .isCleared)
        try values.encode(tasks, forKey: .tasks)
        try values.encode(experience, forKey: .experience)
        try values.encode(petIDs, forKey: .petIDs)
    }

    /// Always use these bounded entry points at transport/cache boundaries.
    static func decode(_ data: Data) throws -> WatchSnapshot {
        guard data.count <= maximumBytes else { throw WatchSnapshotError.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw WatchSnapshotError.tooLarge }
        return data
    }

    fileprivate static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 96 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                [UInt8(45), 46, 58, 95].contains($0)
        }
    }

    private func validate() throws {
        guard version == Self.currentVersion else { throw WatchSnapshotError.unsupportedVersion }
        let start = sessionStartedAt.timeIntervalSince1970
        let generated = generatedAt.timeIntervalSince1970
                guard start.isFinite, generated.isFinite,
              (0...Self.maximumTimestamp).contains(start),
              (0...Self.maximumTimestamp).contains(generated),
              (1...Self.maximumRevision).contains(revision),
              tasks.count <= Self.maximumTasks, petIDs.count <= Self.maximumPets,
              (0...Self.maximumExperience).contains(experience),
              Set(tasks.map(\.id)).count == tasks.count,
              Set(petIDs).count == petIDs.count, petIDs.allSatisfy(Self.validID),
              !isCleared || (tasks.isEmpty && experience == 0 && petIDs.isEmpty) else {
            throw WatchSnapshotError.invalidValue
        }
        try tasks.forEach { try $0.validate() }
    }

    /// UTC day boundaries, independent of the user's locale/calendar/time zone.
    func isStale(at now: Date) -> Bool {
        let age = now.timeIntervalSince(generatedAt)
        return age > 86_400 || age < -Self.futureTolerance ||
            floor(now.timeIntervalSince1970 / 86_400) != floor(generatedAt.timeIntervalSince1970 / 86_400)
    }

    /// Wall-clock changes never affect ordering. A process/consent session has a
    /// fixed epoch and increasing revisions; another UUID needs a strictly newer epoch.
    func supersedes(_ previous: WatchSnapshot) -> Bool {
        if sessionID == previous.sessionID {
            return sessionStartedAt == previous.sessionStartedAt && revision > previous.revision
        }
        return sessionStartedAt > previous.sessionStartedAt
    }

    /// Purge all display data without advancing (or discarding) the replay barrier.
    var tombstone: WatchSnapshot {
        WatchSnapshot(sessionID: sessionID, sessionStartedAt: sessionStartedAt,
                      revision: revision, generatedAt: generatedAt, isCleared: true)
    }
}

/// Pure reducer shared with offline tests. A tombstone remains as an ordering barrier,
/// but exposes no display payload. Ignored duplicates never refresh `receivedAt`.
struct WatchSnapshotState: Equatable, Sendable {
    private(set) var latest: WatchSnapshot?
    private(set) var receivedAt: Date?
    private(set) var isLocallyBlocked = false

    var visibleSnapshot: WatchSnapshot? {
        guard !isLocallyBlocked, let latest, !latest.isCleared else { return nil }
        return latest
    }

    mutating func setLocallyBlocked(_ blocked: Bool) {
        isLocallyBlocked = blocked
        if blocked { latest = latest?.tombstone }
        // Unblocking never restores payload or removes the last ordering barrier.
    }

    /// Cache restoration is not a new receipt. After a clock rollback, retain the
    /// valid ordering metadata but discard a now-future payload, rather than lose
    /// its replay barrier by rejecting/removing the entire cache.
    mutating func restore(_ data: Data, now: Date) throws {
        let cached = try WatchSnapshot.decode(data)
        guard now.timeIntervalSince1970.isFinite else { throw WatchSnapshotError.invalidValue }
        latest = isLocallyBlocked || cached.generatedAt.timeIntervalSince(now) > WatchSnapshot.futureTolerance
            ? cached.tombstone : cached
        receivedAt = nil
    }

    @discardableResult
    mutating func receive(_ data: Data, now: Date) throws -> Bool {
        let incoming = try WatchSnapshot.decode(data)
        // Clears have no display data and must work even when the clocks disagree.
        // While locally hidden, retain ordering from valid packets, never payload.
        guard now.timeIntervalSince1970.isFinite,
              isLocallyBlocked || incoming.isCleared ||
                incoming.generatedAt.timeIntervalSince(now) <= WatchSnapshot.futureTolerance else {
            throw WatchSnapshotError.invalidValue
        }
        if let latest, !incoming.supersedes(latest) { return false }
        latest = isLocallyBlocked ? incoming.tombstone : incoming
        receivedAt = now
        return true
    }
}

/// The actual Watch cache/consent implementation, Foundation-only for offline tests.
/// Persist only the reducer's sanitized state, NEVER the raw incoming packet.
struct WatchSnapshotPersistence {
    static let cacheKey = "goalpet.watch.snapshot.v1"
    static let blockedKey = "goalpet.watch.locallyBlocked.v1"
    private let defaults: UserDefaults
    private(set) var state = WatchSnapshotState()

    init(defaults: UserDefaults, now: Date) {
        self.defaults = defaults
        state.setLocallyBlocked(defaults.bool(forKey: Self.blockedKey))
        if let data = defaults.data(forKey: Self.cacheKey) {
            do {
                try state.restore(data, now: now)
                try persist()
            } catch {
                defaults.removeObject(forKey: Self.cacheKey)
            }
        }
    }

    mutating func setLocallyBlocked(_ blocked: Bool) throws {
        // Block first so an interrupted cache rewrite is sanitized on next launch.
        if blocked { defaults.set(true, forKey: Self.blockedKey) }
        state.setLocallyBlocked(blocked)
        try persist()
        // Explicit re-enable keeps the tombstone durable before lifting the block.
        if !blocked { defaults.set(false, forKey: Self.blockedKey) }
    }

    @discardableResult
    mutating func receive(_ data: Data, now: Date) throws -> Bool {
        guard try state.receive(data, now: now) else { return false }
        try persist()
        return true
    }

    private func persist() throws {
        if let latest = state.latest {
            defaults.set(try latest.encoded(), forKey: Self.cacheKey)
        } else {
            defaults.removeObject(forKey: Self.cacheKey)
        }
    }
}
