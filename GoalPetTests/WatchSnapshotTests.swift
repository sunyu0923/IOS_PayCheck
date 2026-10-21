// Contract, publisher ordering and Watch persistence tests. Isolated defaults;
// no WCSession creation, live HealthKit store, network or rewards.
import Foundation
import XCTest
@testable import GoalPet

final class WatchSnapshotTests: XCTestCase {
    private let sessionA = UUID()
    private let sessionB = UUID()
    // Exactly noon UTC on a deterministic day; no locale/time-zone dependency.
    private let now = Date(timeIntervalSince1970: 20_000 * 86_400 + 43_200)

    private var task: WatchTaskSnapshot {
        WatchTaskSnapshot(id: "daily:meal:2024-10-04", title: "记录一餐（UTC 今日）", isComplete: true)
    }

    private func snapshot(revision: Int64 = 1, generatedAt: Date? = nil,
                          sessionID: UUID? = nil, sessionStartedAt: Date? = nil,
                          cleared: Bool = false, tasks: [WatchTaskSnapshot]? = nil,
                          experience: Int? = nil, petIDs: [String]? = nil) -> WatchSnapshot {
        WatchSnapshot(sessionID: sessionID ?? sessionA,
            sessionStartedAt: sessionStartedAt ?? now.addingTimeInterval(-60),
            revision: revision, generatedAt: generatedAt ?? now, isCleared: cleared,
            tasks: tasks ?? (cleared ? [] : [task]),
            experience: experience ?? (cleared ? 0 : 30),
            petIDs: petIDs ?? (cleared ? [] : ["pet.cat_1"]))
    }

    private func object(_ value: WatchSnapshot? = nil) throws -> [String: Any] {
        let data = try (value ?? snapshot()).encoded()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func modified(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var value = try object()
        change(&value)
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suite = "GoalPet.WatchSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    func testRoundTripPreservesUnicodeAndAllowedPayload() throws {
        let original = snapshot()
        XCTAssertEqual(try WatchSnapshot.decode(original.encoded()), original)
        XCTAssertLessThan(try original.encoded().count, WatchSnapshot.maximumBytes)
    }

    func testWireKeysContainNoHealthFinanceFoodPhotosOrMembers() throws {
        let value = try object()
        XCTAssertEqual(Set(value.keys), Set(["version", "sessionID", "sessionStartedAt", "revision",
            "generatedAt", "isCleared", "tasks", "experience", "petIDs"]))
        let tasks = try XCTUnwrap(value["tasks"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(tasks.first).keys), Set(["id", "title", "isComplete"]))
    }

    func testUnknownTopLevelFieldsAreRejected() throws {
        for field in ["health", "steps", "heartRate", "amountMinor", "photos", "members", "food", "awardXP"] {
            let data = try modified { $0[field] = 42 }
            XCTAssertThrowsError(try WatchSnapshot.decode(data), field)
        }
    }

    func testUnknownTaskFieldsAreRejected() throws {
        let data = try modified {
            $0["tasks"] = [["id": "task", "title": "Task", "isComplete": false, "calories": 10]]
        }
        XCTAssertThrowsError(try WatchSnapshot.decode(data))
    }

    func testMissingAndNullFieldsAreRejected() throws {
        for field in try object().keys {
            XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0.removeValue(forKey: field) }))
            XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0[field] = NSNull() }))
        }
    }

    func testUnknownAndOldVersionsAreRejected() throws {
        for version in [0, 2, -1, 999] {
            let data = try modified { $0["version"] = version }
            XCTAssertThrowsError(try WatchSnapshot.decode(data)) { error in
                XCTAssertEqual(error as? WatchSnapshotError, .unsupportedVersion)
            }
        }
    }

    func testIncorrectFieldTypesAreRejected() throws {
        for field in ["version", "revision", "generatedAt", "sessionStartedAt", "experience", "isCleared", "tasks", "petIDs"] {
            XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0[field] = "wrong" }))
        }
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["sessionID"] = "not-a-uuid" }))
    }

    func testMalformedTruncatedAndEmptyJSONAreRejected() throws {
        for text in ["", "{", "[]", "null", "{\"version\":1}"] {
            XCTAssertThrowsError(try WatchSnapshot.decode(Data(text.utf8)))
        }
    }

    func testDecodeRejectsOversizedDataBeforeParsing() {
        let data = Data(repeating: 32, count: WatchSnapshot.maximumBytes + 1)
        XCTAssertThrowsError(try WatchSnapshot.decode(data)) { error in
            XCTAssertEqual(error as? WatchSnapshotError, .tooLarge)
        }
    }

    func testDecodeAllowsValidJSONAtExactByteLimit() throws {
        var data = try snapshot().encoded()
        data.append(Data(repeating: 32, count: WatchSnapshot.maximumBytes - data.count))
        XCTAssertEqual(try WatchSnapshot.decode(data), snapshot())
    }

    func testTooManyTasksAreRejectedByEncoderAndDecoder() throws {
        let tasks = (0...WatchSnapshot.maximumTasks).map {
            WatchTaskSnapshot(id: "task:\($0)", title: "Task", isComplete: false)
        }
        XCTAssertThrowsError(try snapshot(tasks: tasks).encoded())
        let data = try modified { $0["tasks"] = tasks.map { ["id": $0.id, "title": $0.title, "isComplete": false] as [String: Any] } }
        XCTAssertThrowsError(try WatchSnapshot.decode(data))
    }

    func testTooManyPetsAreRejectedByEncoderAndDecoder() throws {
        let pets = (0...WatchSnapshot.maximumPets).map { "pet\($0)" }
        XCTAssertThrowsError(try snapshot(petIDs: pets).encoded())
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["petIDs"] = pets }))
    }

    func testDuplicateTaskAndPetIDsAreRejected() throws {
        XCTAssertThrowsError(try snapshot(tasks: [task, task]).encoded())
        XCTAssertThrowsError(try snapshot(petIDs: ["cat", "cat"]).encoded())
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["petIDs"] = ["cat", "cat"] }))
    }

    func testIdentifiersAreBoundedAndNotArbitraryTextOrURLs() {
        for id in ["", "member name", "https://example.com/photo", "猫", String(repeating: "a", count: 97)] {
            XCTAssertThrowsError(try snapshot(petIDs: [id]).encoded())
            XCTAssertThrowsError(try snapshot(tasks: [WatchTaskSnapshot(id: id, title: "Task", isComplete: false)]).encoded())
        }
    }

    func testTitlesAreNonemptyControlFreeAndUTF8Bounded() {
        for title in ["", "   ", "Task\nName", "Task\u{0000}", String(repeating: "猫", count: 54)] {
            XCTAssertThrowsError(try snapshot(tasks: [WatchTaskSnapshot(id: "task", title: title, isComplete: false)]).encoded())
        }
    }

    func testMaximumLegalPayloadFitsWireBudget() throws {
        let tasks = (0..<WatchSnapshot.maximumTasks).map {
            WatchTaskSnapshot(id: "task:\($0)", title: String(repeating: "猫", count: 53), isComplete: false)
        }
        let pets = (0..<WatchSnapshot.maximumPets).map { "pet\($0)" + String(repeating: "a", count: 90) }
        let value = snapshot(revision: WatchSnapshot.maximumRevision, tasks: tasks,
                             experience: WatchSnapshot.maximumExperience, petIDs: pets)
        let data = try value.encoded()
        XCTAssertLessThanOrEqual(data.count, WatchSnapshot.maximumBytes)
        XCTAssertEqual(try WatchSnapshot.decode(data), value)
    }

    func testInvalidExperienceIsRejected() throws {
        for xp in [-1, WatchSnapshot.maximumExperience + 1] {
            XCTAssertThrowsError(try snapshot(experience: xp).encoded())
            XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["experience"] = xp }))
        }
    }

    func testInvalidRevisionIsRejected() throws {
        for revision in [0, -1, WatchSnapshot.maximumRevision + 1] {
            XCTAssertThrowsError(try snapshot(revision: revision).encoded())
            XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["revision"] = revision }))
        }
    }

    func testInvalidDatesAreRejected() throws {
        for date in [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: 4_102_444_801),
                     Date(timeIntervalSince1970: .infinity)] {
            XCTAssertThrowsError(try snapshot(generatedAt: date).encoded())
            XCTAssertThrowsError(try snapshot(sessionStartedAt: date).encoded())
        }
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["generatedAt"] = -1 }))
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["sessionStartedAt"] = WatchSnapshot.maximumTimestamp + 1 }))
    }

    func testTombstoneMustBeEmpty() throws {
        XCTAssertThrowsError(try snapshot(cleared: true, tasks: [task]).encoded())
        XCTAssertThrowsError(try snapshot(cleared: true, experience: 1).encoded())
        XCTAssertThrowsError(try snapshot(cleared: true, petIDs: ["cat"]).encoded())
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["isCleared"] = true }))
        XCTAssertEqual(try WatchSnapshot.decode(snapshot(cleared: true).encoded()), snapshot(cleared: true))
    }

    func testFirstSnapshotRecordsReceiptAndVisibleState() throws {
        var state = WatchSnapshotState()
        XCTAssertTrue(try state.receive(snapshot().encoded(), now: now))
        XCTAssertEqual(state.visibleSnapshot, snapshot())
        XCTAssertEqual(state.receivedAt, now)
    }

    func testDuplicateDoesNotChangeReceiptTime() throws {
        var state = WatchSnapshotState()
        let data = try snapshot().encoded()
        try state.receive(data, now: now)
        XCTAssertFalse(try state.receive(data, now: now.addingTimeInterval(10)))
        XCTAssertEqual(state.receivedAt, now)
    }

    func testHigherRevisionWithSameWallClockWins() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot().encoded(), now: now)
        let latest = snapshot(revision: 2)
        XCTAssertTrue(try state.receive(latest.encoded(), now: now))
        XCTAssertEqual(state.latest, latest)
    }

    func testLowerRevisionCannotWinWithNewerTimestamp() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot(revision: 2).encoded(), now: now)
        XCTAssertFalse(try state.receive(snapshot(revision: 1, generatedAt: now.addingTimeInterval(1)).encoded(), now: now))
        XCTAssertEqual(state.latest?.revision, 2)
    }

    func testHigherRevisionWinsAfterWallClockRollback() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot().encoded(), now: now)
        let rollback = now.addingTimeInterval(-3_600)
        let fresh = snapshot(revision: 2, generatedAt: rollback)
        XCTAssertTrue(try state.receive(fresh.encoded(), now: rollback))
        XCTAssertEqual(state.visibleSnapshot, fresh)
        XCTAssertFalse(fresh.isStale(at: rollback))
    }

    func testSameSessionCannotChangeItsStartTimestamp() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot().encoded(), now: now)
        XCTAssertFalse(try state.receive(snapshot(revision: 2, sessionStartedAt: now.addingTimeInterval(-30)).encoded(), now: now))
    }

    func testNewerSessionCanResetRevision() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot(revision: 100).encoded(), now: now)
        let next = now.addingTimeInterval(1)
        let value = snapshot(sessionID: sessionB, sessionStartedAt: next)
        // A logical epoch can be ahead of generatedAt without making data future.
        XCTAssertTrue(try state.receive(value.encoded(), now: now))
        XCTAssertEqual(state.latest?.revision, 1)
        XCTAssertEqual(state.latest?.sessionID, sessionB)
    }

    func testRetiredSessionCannotReturnWithHigherRevisionOrTimestamp() throws {
        var state = WatchSnapshotState()
        let next = now.addingTimeInterval(1)
        try state.receive(snapshot(generatedAt: next, sessionID: sessionB, sessionStartedAt: next).encoded(), now: next)
        XCTAssertFalse(try state.receive(snapshot(revision: 999, generatedAt: next.addingTimeInterval(1)).encoded(), now: next))
        XCTAssertEqual(state.latest?.sessionID, sessionB)
    }

    func testDifferentSessionCannotReusePreviousEpoch() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot().encoded(), now: now)
        XCTAssertFalse(try state.receive(snapshot(revision: 2, sessionID: sessionB).encoded(), now: now))
    }

    func testTombstoneClearsPayloadAndBlocksDelayedSnapshot() throws {
        var state = WatchSnapshotState()
        let old = try snapshot().encoded()
        try state.receive(old, now: now)
        let clear = snapshot(revision: 2, cleared: true)
        XCTAssertTrue(try state.receive(clear.encoded(), now: now))
        XCTAssertNil(state.visibleSnapshot)
        XCTAssertEqual(state.latest, clear)
        XCTAssertFalse(try state.receive(old, now: now.addingTimeInterval(10)))
        XCTAssertNil(state.visibleSnapshot)
    }

    func testCachedTombstoneStillBlocksOldStateAfterRelaunch() throws {
        let cachedClear = try snapshot(revision: 2, cleared: true).encoded()
        var restored = WatchSnapshotState()
        try restored.receive(cachedClear, now: now)
        XCTAssertFalse(try restored.receive(snapshot().encoded(), now: now))
        XCTAssertNil(restored.visibleSnapshot)
    }

    func testNewOptInSessionCanReplaceTombstone() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot(revision: 10, cleared: true).encoded(), now: now)
        let next = now.addingTimeInterval(1)
        XCTAssertTrue(try state.receive(snapshot(generatedAt: next, sessionID: sessionB, sessionStartedAt: next).encoded(), now: next))
        XCTAssertNotNil(state.visibleSnapshot)
    }

    func testOldTombstoneCannotClearNewOptInSession() throws {
        var state = WatchSnapshotState()
        let next = now.addingTimeInterval(1)
        try state.receive(snapshot(generatedAt: next, sessionID: sessionB, sessionStartedAt: next).encoded(), now: next)
        XCTAssertFalse(try state.receive(snapshot(revision: 999, cleared: true).encoded(), now: next))
        XCTAssertNotNil(state.visibleSnapshot)
    }

    func testInvalidIncomingDataDoesNotMutateValidatedState() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot(cleared: true).encoded(), now: now)
        let before = state
        XCTAssertThrowsError(try state.receive(modified { $0["version"] = 2 }, now: now))
        XCTAssertEqual(state, before)
    }

    func testFarFutureSnapshotCannotPoisonOrdering() throws {
        var state = WatchSnapshotState()
        let future = snapshot(generatedAt: now.addingTimeInterval(301))
        XCTAssertThrowsError(try state.receive(future.encoded(), now: now))
        XCTAssertNil(state.latest)
        XCTAssertTrue(try state.receive(snapshot().encoded(), now: now))
    }

    func testClockRollbackDoesNotPreventPrivacyClear() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot().encoded(), now: now)
        let clear = snapshot(revision: 2, generatedAt: now.addingTimeInterval(1), cleared: true)
        XCTAssertTrue(try state.receive(clear.encoded(), now: now.addingTimeInterval(-3_600)))
        XCTAssertNil(state.visibleSnapshot)
        XCTAssertEqual(state.latest, clear)
    }

    func testDirectCodableDecodeAlsoEnforcesSchemaAndBounds() throws {
        let extraField = try modified { $0["health"] = 10 }
        XCTAssertThrowsError(try JSONDecoder().decode(WatchSnapshot.self, from: extraField))
        let invalidXP = try modified { $0["experience"] = -1 }
        XCTAssertThrowsError(try JSONDecoder().decode(WatchSnapshot.self, from: invalidXP))
    }

    func testSameUTCDayIsFreshAndMidnightMakesItStale() {
        let value = snapshot()
        XCTAssertFalse(value.isStale(at: now.addingTimeInterval(60)))
        XCTAssertTrue(value.isStale(at: now.addingTimeInterval(43_200)))
        XCTAssertTrue(value.isStale(at: now.addingTimeInterval(86_401)))
    }

    func testClockRollbackDoesNotMakeFutureDataFresh() {
        XCTAssertTrue(snapshot().isStale(at: now.addingTimeInterval(-301)))
    }

    func testStaleSnapshotCanBeReceivedButRemainsStale() throws {
        var state = WatchSnapshotState()
        let later = now.addingTimeInterval(86_401)
        XCTAssertTrue(try state.receive(snapshot().encoded(), now: later))
        XCTAssertEqual(state.visibleSnapshot?.isStale(at: later), true)
        XCTAssertEqual(state.receivedAt, later)
    }

    func testRevisionAboveInt32MaximumRoundTripsAndOrders() throws {
        let revision = Int64(Int32.max) + 1
        let value = snapshot(revision: revision)
        XCTAssertEqual(MemoryLayout.size(ofValue: value.revision), 8)
        XCTAssertEqual(try WatchSnapshot.decode(value.encoded()).revision, revision)
        var state = WatchSnapshotState()
        try state.receive(snapshot(revision: Int64(Int32.max)).encoded(), now: now)
        XCTAssertTrue(try state.receive(value.encoded(), now: now))
    }

    func testMaximumRevisionIsExactlyPreservedWithoutIntNarrowing() throws {
        let revision: Int64 = 9_007_199_254_740_991
        XCTAssertEqual(WatchSnapshot.maximumRevision, revision)
        XCTAssertEqual(try WatchSnapshot.decode(snapshot(revision: revision).encoded()).revision, revision)
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["revision"] = Int64.max }))
        XCTAssertThrowsError(try WatchSnapshot.decode(modified { $0["revision"] = 1.5 }))
    }

    func testLogicalEpochCanBeAheadOfWallClockButRemainsBounded() throws {
        let value = snapshot(sessionStartedAt: Date(timeIntervalSince1970: WatchSnapshot.maximumTimestamp))
        var state = WatchSnapshotState()
        XCTAssertTrue(try state.receive(value.encoded(), now: now))
        XCTAssertFalse(value.isStale(at: now))
        XCTAssertEqual(try WatchSnapshot.decode(value.encoded()), value)
    }

    func testNewEpochOnlyNeedsToExceedPreviousEpochNotPreviousGeneration() throws {
        var state = WatchSnapshotState()
        try state.receive(snapshot().encoded(), now: now)
        let rollback = now.addingTimeInterval(-3_600)
        let value = snapshot(generatedAt: rollback, sessionID: sessionB,
                             sessionStartedAt: now.addingTimeInterval(-59))
        XCTAssertTrue(try state.receive(value.encoded(), now: rollback))
        XCTAssertEqual(state.visibleSnapshot, value)
    }

    func testPublisherRollbackKeepsEpochAndAdvancesInt64Revision() throws {
        try withDefaults { defaults, _ in
            var publisher = WatchSnapshotSequence(defaults: defaults)
            let first = try publisher.makeSnapshot(tasks: [task], cleared: false, now: now)
            let rollback = now.addingTimeInterval(-3_600)
            let next = try publisher.makeSnapshot(tasks: [task], cleared: false, now: rollback)
            XCTAssertEqual(next.sessionID, first.sessionID)
            XCTAssertEqual(next.sessionStartedAt, first.sessionStartedAt)
            XCTAssertEqual(next.revision, first.revision + 1)
            XCTAssertEqual(next.generatedAt, rollback)
            XCTAssertEqual(defaults.double(forKey: WatchSnapshotSequence.watermarkKey),
                           first.sessionStartedAt.timeIntervalSince1970)
            var state = WatchSnapshotState()
            try state.receive(first.encoded(), now: now)
            XCTAssertTrue(try state.receive(next.encoded(), now: rollback))
            XCTAssertFalse(next.isStale(at: rollback))
        }
    }

    func testPublisherRelaunchAfterRollbackAllocatesPersistentNewEpoch() throws {
        try withDefaults { defaults, suite in
            var publisher = WatchSnapshotSequence(defaults: defaults)
            let first = try publisher.makeSnapshot(cleared: false, now: now)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            var relaunched = WatchSnapshotSequence(defaults: reopened)
            let rollback = now.addingTimeInterval(-3_600)
            let next = try relaunched.makeSnapshot(cleared: false, now: rollback)
            XCTAssertNotEqual(next.sessionID, first.sessionID)
            XCTAssertGreaterThan(next.sessionStartedAt, first.sessionStartedAt)
            XCTAssertEqual(next.revision, 1)
            XCTAssertEqual(next.generatedAt, rollback)
            var state = WatchSnapshotState()
            try state.receive(first.encoded(), now: now)
            XCTAssertTrue(try state.receive(next.encoded(), now: rollback))
        }
    }

    func testPublisherClearRelaunchAndOptInAfterRollbackRemainFreshAndOrdered() throws {
        try withDefaults { defaults, suite in
            var publisher = WatchSnapshotSequence(defaults: defaults)
            let old = try publisher.makeSnapshot(tasks: [task], cleared: false, now: now)
            var state = WatchSnapshotState()
            try state.receive(old.encoded(), now: now)
            let rollback = now.addingTimeInterval(-7_200)
            publisher.beginSession() // Phone opts out.
            let clear = try publisher.makeSnapshot(cleared: true, now: rollback)
            XCTAssertTrue(try state.receive(clear.encoded(), now: rollback))
            XCTAssertNil(state.visibleSnapshot)
            XCTAssertEqual(clear.generatedAt, rollback)

            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            var relaunched = WatchSnapshotSequence(defaults: reopened)
            let launchClear = try relaunched.makeSnapshot(cleared: true, now: rollback)
            XCTAssertTrue(try state.receive(launchClear.encoded(), now: rollback))
            relaunched.beginSession() // Explicit phone opt-in.
            let fresh = try relaunched.makeSnapshot(tasks: [task], cleared: false, now: rollback)
            XCTAssertTrue(try state.receive(fresh.encoded(), now: rollback))
            XCTAssertEqual(fresh.generatedAt, rollback)
            XCTAssertFalse(fresh.isStale(at: rollback))
            XCTAssertGreaterThan(fresh.sessionStartedAt, launchClear.sessionStartedAt)
            XCTAssertFalse(try state.receive(clear.encoded(), now: rollback))
            XCTAssertEqual(state.visibleSnapshot, fresh)
        }
    }

    func testPublisherRepeatedRelaunchesAtFixedClockNeverReuseEpoch() throws {
        try withDefaults { defaults, _ in
            var previous: WatchSnapshot?
            for _ in 0..<20 {
                var publisher = WatchSnapshotSequence(defaults: defaults)
                let next = try publisher.makeSnapshot(cleared: false, now: now)
                if let previous { XCTAssertTrue(next.supersedes(previous)) }
                XCTAssertEqual(next.generatedAt, now)
                XCTAssertEqual(next.revision, 1)
                previous = next
            }
        }
    }

    func testPublisherMigratesLegacyGenerationWatermarkWithoutFuturePayload() throws {
        try withDefaults { defaults, _ in
            let legacyFuture = now.addingTimeInterval(7_200)
            defaults.set(legacyFuture.timeIntervalSince1970, forKey: WatchSnapshotSequence.watermarkKey)
            var publisher = WatchSnapshotSequence(defaults: defaults)
            let fresh = try publisher.makeSnapshot(cleared: false, now: now)
            XCTAssertGreaterThan(fresh.sessionStartedAt, legacyFuture)
            XCTAssertEqual(fresh.generatedAt, now)
            var state = WatchSnapshotState()
            try state.receive(snapshot(generatedAt: legacyFuture, cleared: true).encoded(), now: now)
            XCTAssertTrue(try state.receive(fresh.encoded(), now: now))
        }
    }

    func testPublisherEpochExhaustionFailsClosedWithoutResettingWatermark() throws {
        try withDefaults { defaults, _ in
            defaults.set(WatchSnapshot.maximumTimestamp, forKey: WatchSnapshotSequence.watermarkKey)
            var publisher = WatchSnapshotSequence(defaults: defaults)
            XCTAssertThrowsError(try publisher.makeSnapshot(cleared: false, now: now))
            publisher.beginSession()
            XCTAssertThrowsError(try publisher.makeSnapshot(cleared: true, now: now))
            XCTAssertEqual(defaults.double(forKey: WatchSnapshotSequence.watermarkKey), WatchSnapshot.maximumTimestamp)
        }
    }

    func testPublisherRejectsCorruptWatermarkRatherThanReusingOldEpoch() throws {
        try withDefaults { defaults, _ in
            let invalidValues: [Any] = [-1.0, WatchSnapshot.maximumTimestamp + 1, "corrupt"]
            for invalid in invalidValues {
                defaults.set(invalid, forKey: WatchSnapshotSequence.watermarkKey)
                var publisher = WatchSnapshotSequence(defaults: defaults)
                XCTAssertThrowsError(try publisher.makeSnapshot(cleared: false, now: now))
            }
        }
    }

    func testInvalidPublisherInputDoesNotConsumeOrderingOrPersistPayload() throws {
        try withDefaults { defaults, suite in
            var publisher = WatchSnapshotSequence(defaults: defaults)
            XCTAssertThrowsError(try publisher.makeSnapshot(experience: -1, cleared: false, now: now))
            XCTAssertNil(defaults.object(forKey: WatchSnapshotSequence.watermarkKey))
            let first = try publisher.makeSnapshot(tasks: [task], cleared: false, now: now)
            XCTAssertEqual(first.revision, 1)
            XCTAssertThrowsError(try publisher.makeSnapshot(cleared: false, now: Date(timeIntervalSince1970: -1)))
            let second = try publisher.makeSnapshot(cleared: false, now: now)
            XCTAssertEqual(second.revision, 2)
            let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
            XCTAssertEqual(Set(stored.keys), Set([WatchSnapshotSequence.watermarkKey]))
        }
    }

    func testLocalClearImmediatelyPurgesPayloadAndPersistsReplayBarrier() throws {
        try withDefaults { defaults, _ in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            let data = try snapshot().encoded()
            try cache.receive(data, now: now)
            try cache.setLocallyBlocked(true)
            XCTAssertTrue(cache.state.isLocallyBlocked)
            XCTAssertTrue(defaults.bool(forKey: WatchSnapshotPersistence.blockedKey))
            XCTAssertNil(cache.state.visibleSnapshot)
            let stored = try WatchSnapshot.decode(XCTUnwrap(defaults.data(forKey: WatchSnapshotPersistence.cacheKey)))
            XCTAssertEqual(stored, snapshot().tombstone)
            XCTAssertTrue(stored.tasks.isEmpty)
            XCTAssertEqual(stored.experience, 0)
            XCTAssertTrue(stored.petIDs.isEmpty)
            XCTAssertFalse(try cache.receive(data, now: now.addingTimeInterval(10)))
        }
    }

    func testLocalBlockSurvivesRelaunchAndSameApplicationContextReplay() throws {
        try withDefaults { defaults, suite in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            let context = try snapshot().encoded()
            try cache.receive(context, now: now)
            try cache.setLocallyBlocked(true)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            var restored = WatchSnapshotPersistence(defaults: reopened, now: now)
            XCTAssertTrue(restored.state.isLocallyBlocked)
            XCTAssertFalse(try restored.receive(context, now: now))
            XCTAssertNil(restored.state.visibleSnapshot)
            XCTAssertEqual(restored.state.latest, snapshot().tombstone)
            XCTAssertNil(restored.state.receivedAt)
        }
    }

    func testHiddenUpdatesPersistOnlyNewestTombstoneIncludingNewPhoneOptIn() throws {
        try withDefaults { defaults, _ in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            try cache.receive(snapshot().encoded(), now: now)
            try cache.setLocallyBlocked(true)
            let newer = snapshot(revision: 2)
            XCTAssertTrue(try cache.receive(newer.encoded(), now: now))
            let phoneOptIn = snapshot(sessionID: sessionB, sessionStartedAt: now)
            XCTAssertTrue(try cache.receive(phoneOptIn.encoded(), now: now))
            XCTAssertTrue(cache.state.isLocallyBlocked)
            XCTAssertNil(cache.state.visibleSnapshot)
            XCTAssertEqual(cache.state.latest, phoneOptIn.tombstone)
            let stored = try WatchSnapshot.decode(XCTUnwrap(defaults.data(forKey: WatchSnapshotPersistence.cacheKey)))
            XCTAssertEqual(stored, phoneOptIn.tombstone)
            XCTAssertTrue(defaults.bool(forKey: WatchSnapshotPersistence.blockedKey))
        }
    }

    func testExplicitWatchReenableKeepsBarrierAndRequiresStrictlyNewerUpdate() throws {
        try withDefaults { defaults, suite in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            try cache.receive(snapshot().encoded(), now: now)
            try cache.setLocallyBlocked(true)
            // The Watch drains its receivedApplicationContext before lifting the block.
            let currentContext = try snapshot(revision: 2).encoded()
            try cache.receive(currentContext, now: now)
            try cache.setLocallyBlocked(false)
            XCTAssertFalse(defaults.bool(forKey: WatchSnapshotPersistence.blockedKey))
            XCTAssertNil(cache.state.visibleSnapshot)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            var restored = WatchSnapshotPersistence(defaults: reopened, now: now)
            XCTAssertFalse(restored.state.isLocallyBlocked)
            XCTAssertFalse(try restored.receive(currentContext, now: now))
            XCTAssertFalse(try restored.receive(snapshot().encoded(), now: now))
            XCTAssertNil(restored.state.visibleSnapshot)
            let fresh = snapshot(revision: 3)
            XCTAssertTrue(try restored.receive(fresh.encoded(), now: now))
            XCTAssertEqual(restored.state.visibleSnapshot, fresh)
        }
    }

    func testBlockingBeforeAnySnapshotSurvivesRelaunchAndHidesFirstArrival() throws {
        try withDefaults { defaults, _ in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            try cache.setLocallyBlocked(true)
            XCTAssertNil(defaults.data(forKey: WatchSnapshotPersistence.cacheKey))
            var restored = WatchSnapshotPersistence(defaults: defaults, now: now)
            XCTAssertTrue(restored.state.isLocallyBlocked)
            XCTAssertTrue(try restored.receive(snapshot().encoded(), now: now))
            XCTAssertNil(restored.state.visibleSnapshot)
            XCTAssertEqual(restored.state.latest, snapshot().tombstone)
        }
    }

    func testPersistedBlockSanitizesPayloadLeftByInterruptedClear() throws {
        try withDefaults { defaults, _ in
            defaults.set(try snapshot().encoded(), forKey: WatchSnapshotPersistence.cacheKey)
            defaults.set(true, forKey: WatchSnapshotPersistence.blockedKey)
            let restored = WatchSnapshotPersistence(defaults: defaults, now: now)
            XCTAssertTrue(restored.state.isLocallyBlocked)
            XCTAssertNil(restored.state.visibleSnapshot)
            let stored = try WatchSnapshot.decode(XCTUnwrap(defaults.data(forKey: WatchSnapshotPersistence.cacheKey)))
            XCTAssertEqual(stored, snapshot().tombstone)
        }
    }

    func testMalformedCacheCannotLiftPersistedLocalBlock() throws {
        try withDefaults { defaults, _ in
            defaults.set(Data("invalid".utf8), forKey: WatchSnapshotPersistence.cacheKey)
            defaults.set(true, forKey: WatchSnapshotPersistence.blockedKey)
            var restored = WatchSnapshotPersistence(defaults: defaults, now: now)
            XCTAssertTrue(restored.state.isLocallyBlocked)
            XCTAssertNil(defaults.data(forKey: WatchSnapshotPersistence.cacheKey))
            try restored.receive(snapshot().encoded(), now: now)
            XCTAssertNil(restored.state.visibleSnapshot)
        }
    }

    func testInvalidHiddenUpdateDoesNotChangePersistentBarrierOrConsent() throws {
        try withDefaults { defaults, _ in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            try cache.receive(snapshot().encoded(), now: now)
            try cache.setLocallyBlocked(true)
            let before = cache.state
            let stored = defaults.data(forKey: WatchSnapshotPersistence.cacheKey)
            XCTAssertThrowsError(try cache.receive(modified { $0["revision"] = -1 }, now: now))
            XCTAssertEqual(cache.state, before)
            XCTAssertEqual(defaults.data(forKey: WatchSnapshotPersistence.cacheKey), stored)
            XCTAssertTrue(defaults.bool(forKey: WatchSnapshotPersistence.blockedKey))
        }
    }

    func testClockRollbackCacheRestorePreservesBarrierInsteadOfDroppingIt() throws {
        try withDefaults { defaults, _ in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            try cache.receive(snapshot(revision: 5).encoded(), now: now)
            let rollback = now.addingTimeInterval(-3_600)
            var restored = WatchSnapshotPersistence(defaults: defaults, now: rollback)
            XCTAssertEqual(restored.state.latest, snapshot(revision: 5).tombstone)
            XCTAssertNil(restored.state.visibleSnapshot)
            XCTAssertFalse(try restored.receive(snapshot(revision: 4, generatedAt: rollback).encoded(), now: rollback))
            let fresh = snapshot(revision: 6, generatedAt: rollback)
            XCTAssertTrue(try restored.receive(fresh.encoded(), now: rollback))
            XCTAssertEqual(restored.state.visibleSnapshot, fresh)
        }
    }

    func testHiddenFuturePacketIsScrubbedAndCannotReplayAfterReenable() throws {
        try withDefaults { defaults, _ in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            try cache.setLocallyBlocked(true)
            let future = snapshot(generatedAt: now.addingTimeInterval(3_600))
            XCTAssertTrue(try cache.receive(future.encoded(), now: now))
            XCTAssertEqual(cache.state.latest, future.tombstone)
            try cache.setLocallyBlocked(false)
            // Once the wall clock catches up, the same context is still blocked.
            XCTAssertFalse(try cache.receive(future.encoded(), now: future.generatedAt))
            XCTAssertNil(cache.state.visibleSnapshot)
        }
    }

    func testVisibleFutureUpdateIsRejectedWithoutChangingPersistentCache() throws {
        try withDefaults { defaults, _ in
            var cache = WatchSnapshotPersistence(defaults: defaults, now: now)
            try cache.receive(snapshot().encoded(), now: now)
            let before = defaults.data(forKey: WatchSnapshotPersistence.cacheKey)
            let future = snapshot(revision: 2, generatedAt: now.addingTimeInterval(301))
            XCTAssertThrowsError(try cache.receive(future.encoded(), now: now))
            XCTAssertEqual(defaults.data(forKey: WatchSnapshotPersistence.cacheKey), before)
            XCTAssertEqual(cache.state.visibleSnapshot, snapshot())
        }
    }
}
