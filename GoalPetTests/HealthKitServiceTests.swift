// Offline normalization, privacy-state, and cancellation tests. No live HealthKit requests.
import Foundation
import HealthKit
import XCTest
@testable import GoalPet

@MainActor
private final class FakeHealthDataService: HealthDataService {
    var isAvailable = true
    var simulateReadDenial = false
    var requestError: Error?
    var readError: Error?
    var nextSnapshot: HealthSnapshot?
    var suspendRead = false
    var suspendAuthorization = false
    var readStarted: (() -> Void)?
    var authorizationStarted: (() -> Void)?
    private(set) var readSelections: [Set<HealthMetric>] = []
    private(set) var authorizationSelections: [Set<HealthMetric>] = []
    private var pendingRead: CheckedContinuation<HealthSnapshot, Error>?
    private var pendingAuthorization: CheckedContinuation<Void, Error>?

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {
        authorizationSelections.append(metrics)
        if suspendAuthorization {
            try await withCheckedThrowingContinuation { continuation in
                pendingAuthorization = continuation
                authorizationStarted?()
            }
        } else if let requestError {
            throw requestError
        }
    }

    func read(_ metrics: Set<HealthMetric>, now: Date) async throws -> HealthSnapshot {
        readSelections.append(metrics)
        if suspendRead {
            // Deliberately ignores Task cancellation to exercise stale-result guards.
            return try await withCheckedThrowingContinuation { continuation in
                pendingRead = continuation
                readStarted?()
            }
        }
        if let readError { throw readError }
        if simulateReadDenial {
            // HealthKit's read privacy contract: denial looks like an empty store.
            return HealthSnapshot(capturedAt: now, readings: Dictionary(
                uniqueKeysWithValues: metrics.map { ($0, HealthReading.unavailableOrNoData) }
            ))
        }
        return nextSnapshot ?? HealthSnapshot(capturedAt: now, readings: Dictionary(
            uniqueKeysWithValues: metrics.map { ($0, HealthReading.unavailableOrNoData) }
        ))
    }

    func finishRead(_ result: Result<HealthSnapshot, Error>) {
        let pending = pendingRead
        pendingRead = nil
        pending?.resume(with: result)
    }

    func finishAuthorization(_ result: Result<Void, Error>) {
        let pending = pendingAuthorization
        pendingAuthorization = nil
        pending?.resume(with: result)
    }
}

@MainActor
final class HealthKitServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let phone = HealthSource(name: "Phone", bundleIdentifier: "test.phone", version: "1")
    private let watch = HealthSource(name: "Watch source", bundleIdentifier: "test.watch", version: "2")

    private func sleepRecord(_ start: TimeInterval, _ end: TimeInterval,
                             stage: HKCategoryValueSleepAnalysis = .asleepCore,
                             id: UUID = UUID(), source: HealthSource? = nil) -> HealthSleepRecord {
        HealthSleepRecord(id: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                          stage: stage.rawValue, source: source ?? phone)
    }

    private func reading(_ value: Double = 42) -> HealthReading {
        .value(HealthMeasurement(value: value, interval: DateInterval(start: now, end: now),
                                sources: [phone], quantitySamples: [], sleepSamples: []))
    }

    private func quantitySample(_ metric: HealthMetric, unit: HKUnit, value: Double,
                                device: HKDevice? = nil) throws -> HKQuantitySample {
        let type = try XCTUnwrap(metric.sampleType as? HKQuantityType)
        return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                start: now.addingTimeInterval(-60), end: now, device: device, metadata: nil)
    }

    func testExactlySevenReadTypesAndCumulativeMetrics() throws {
        XCTAssertEqual(HealthMetric.allCases.count, 7)
        XCTAssertEqual(Set(HealthMetric.allCases.filter { $0.isCumulative }), [.steps, .activeEnergy, .exerciseMinutes])
        XCTAssertEqual(HealthMetric.exerciseMinutes.quantityIdentifier, .appleExerciseTime)
        XCTAssertEqual(HealthMetric.sleep.sampleType?.identifier, HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
        for metric in HealthMetric.allCases { XCTAssertNotNil(metric.sampleType) }
    }

    func testQuantityUnitConversionsForAllSixQuantityMetrics() throws {
        let cases: [(HealthMetric, HKUnit, Double, Double)] = [
            (.steps, .count(), 1234, 1234),
            (.activeEnergy, .joule(), 4184, 1),
            (.exerciseMinutes, .second(), 150, 2.5),
            (.heartRate, HKUnit.count().unitDivided(by: .second()), 1.5, 90),
            (.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), 55, 55),
            (.bodyMass, .pound(), 100, 45.359237)
        ]
        for (metric, unit, input, expected) in cases {
            let value = try HealthSampleNormalizer.converted(HKQuantity(unit: unit, doubleValue: input), metric: metric)
            XCTAssertEqual(value, expected, accuracy: 0.00001, metric.rawValue)
        }
        XCTAssertEqual(try HealthSampleNormalizer.converted(HKQuantity(unit: .gram(), doubleValue: 70_000),
                                                           metric: .bodyMass), 70, accuracy: 0.00001)
    }

    func testRejectsIncompatibleUnitsAndSleepQuantityConversion() {
        XCTAssertThrowsError(try HealthSampleNormalizer.converted(HKQuantity(unit: .meter(), doubleValue: 1),
                                                                 metric: .bodyMass)) {
            XCTAssertEqual($0 as? HealthDataError, .invalidData)
        }
        XCTAssertThrowsError(try HealthSampleNormalizer.converted(HKQuantity(unit: .minute(), doubleValue: 1),
                                                                 metric: .sleep))
    }

    func testQuantityNormalizationDeduplicatesUUIDAndPreservesSourceDevice() throws {
        let device = HKDevice(name: "Test device", manufacturer: "Test manufacturer", model: "Test model",
                              hardwareVersion: "h1", firmwareVersion: "f1", softwareVersion: "s1",
                              localIdentifier: nil, udiDeviceIdentifier: nil)
        let revision = HKSourceRevision(source: HKSource.default(), version: "test-version")
        let source = HealthSource(revision: revision, device: device)
        let sample = try quantitySample(.bodyMass, unit: .gram(), value: 65_500, device: device)
        let normalized = try HealthSampleNormalizer.quantities([sample, sample], metric: .bodyMass, source: { _ in source })
        let record = try XCTUnwrap(normalized.first)
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(record.id, sample.uuid)
        XCTAssertEqual(record.start, sample.startDate)
        XCTAssertEqual(record.end, sample.endDate)
        XCTAssertEqual(record.value, 65.5)
        XCTAssertEqual(record.source.bundleIdentifier, revision.source.bundleIdentifier)
        XCTAssertEqual(record.source.name, revision.source.name)
        XCTAssertEqual(record.source.version, "test-version")
        XCTAssertEqual(record.source.device?.name, "Test device")
        XCTAssertEqual(record.source.device?.model, "Test model")
        XCTAssertEqual(record.source.device?.softwareVersion, "s1")
        XCTAssertEqual(try HealthSampleNormalizer.quantities([sample], metric: .bodyMass, source: { _ in source }), normalized)
    }

    func testDifferentQuantityUUIDsAreNotDeduplicatedByValueOrTime() throws {
        let first = try quantitySample(.steps, unit: .count(), value: 100)
        let second = try quantitySample(.steps, unit: .count(), value: 100)
        let records = try HealthSampleNormalizer.quantities([first, second, first], metric: .steps, source: { _ in self.phone })
        XCTAssertEqual(Set(records.map { $0.id }), [first.uuid, second.uuid])
        XCTAssertEqual(records.count, 2)
    }

    func testQuantityNormalizationRejectsWrongMetric() throws {
        let sample = try quantitySample(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), value: 60)
        XCTAssertThrowsError(try HealthSampleNormalizer.quantities([sample], metric: .restingHeartRate)) {
            XCTAssertEqual($0 as? HealthDataError, .invalidData)
        }
    }

    func testLatestQuantityNormalizationSortsNewestFirst() throws {
        let type = try XCTUnwrap(HealthMetric.bodyMass.sampleType as? HKQuantityType)
        let old = HKQuantitySample(type: type, quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 60),
                                   start: now.addingTimeInterval(-600), end: now.addingTimeInterval(-600))
        let newest = try quantitySample(.bodyMass, unit: .gramUnit(with: .kilo), value: 61)
        let records = try HealthSampleNormalizer.quantities([old, newest], metric: .bodyMass, source: { _ in self.phone })
        XCTAssertEqual(records.first?.id, newest.uuid)
        XCTAssertEqual(records.first?.value, 61)
    }

    func testSleepClipsBothWindowEdgesAndDeduplicatesUUID() throws {
        let window = HealthSampleNormalizer.last24Hours(endingAt: now)
        let first = sleepRecord(-90_000, -82_800)
        let last = sleepRecord(-3600, 3600, stage: .asleepREM, source: watch)
        let records = try HealthSampleNormalizer.normalizedSleep([last, first, first], window: window)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.id, first.id)
        XCTAssertEqual(records.first?.start, window.start)
        XCTAssertEqual(records.last?.end, window.end)
        XCTAssertEqual(records.first?.source, phone)
        XCTAssertEqual(records.last?.source, watch)
        XCTAssertEqual(HealthSampleNormalizer.asleepMinutes(records), 120)
    }

    func testSleepUnionAcrossOverlappingSourcesAndStages() throws {
        let records = try HealthSampleNormalizer.normalizedSleep([
            sleepRecord(-7200, -3600, stage: .asleepUnspecified),
            sleepRecord(-5400, -1800, stage: .asleepCore, source: watch),
            sleepRecord(-5000, -4000, stage: .asleepDeep),
            sleepRecord(-1800, 0, stage: .asleepREM, source: watch)
        ], window: HealthSampleNormalizer.last24Hours(endingAt: now))
        XCTAssertEqual(records.count, 4) // Preserve per-sample provenance, not merged IDs.
        XCTAssertEqual(HealthSampleNormalizer.asleepMinutes(records), 120)
        XCTAssertEqual(Set(records.map { $0.source }), [phone, watch])
    }

    func testSleepIdenticalIntervalsWithDifferentUUIDsRetainSourcesButCountOnce() throws {
        let first = sleepRecord(-3600, 0)
        let second = sleepRecord(-3600, 0, source: watch)
        let records = try HealthSampleNormalizer.normalizedSleep([first, second],
                                                                 window: HealthSampleNormalizer.last24Hours(endingAt: now))
        XCTAssertEqual(Set(records.map { $0.id }), [first.id, second.id])
        XCTAssertEqual(HealthSampleNormalizer.asleepMinutes(records), 60)
    }

    func testSleepIgnoresInBedAwakeUnknownAndEmptyOrOutsideIntervals() throws {
        let records = try HealthSampleNormalizer.normalizedSleep([
            sleepRecord(-7200, 0, stage: .inBed),
            sleepRecord(-3600, 0, stage: .awake),
            sleepRecord(-3600, -3600),
            sleepRecord(0, 3600),
            sleepRecord(-90_000, -86_400),
            sleepRecord(-10, -20),
            HealthSleepRecord(id: UUID(), start: now.addingTimeInterval(-60), end: now,
                              stage: 999, source: phone)
        ], window: HealthSampleNormalizer.last24Hours(endingAt: now))
        XCTAssertTrue(records.isEmpty)
        // The service must check emptiness BEFORE using this arithmetic helper.
        XCTAssertEqual(HealthSampleNormalizer.asleepMinutes(records), 0)
    }

    func testAwakeDoesNotSubtractAnotherSourcesAsleepInterval() throws {
        let records = try HealthSampleNormalizer.normalizedSleep([
            sleepRecord(-3600, 0), sleepRecord(-1800, 0, stage: .awake, source: watch)
        ], window: HealthSampleNormalizer.last24Hours(endingAt: now))
        XCTAssertEqual(HealthSampleNormalizer.asleepMinutes(records), 60)
        XCTAssertEqual(records.map { $0.source }, [phone])
    }

    func testSleepGapsAreNotCounted() throws {
        let records = try HealthSampleNormalizer.normalizedSleep([
            sleepRecord(-7200, -5400), sleepRecord(-1800, 0)
        ], window: HealthSampleNormalizer.last24Hours(endingAt: now))
        XCTAssertEqual(HealthSampleNormalizer.asleepMinutes(records), 60)
    }

    func testCategoryNormalizationKeepsOriginalUUIDStageAndSource() throws {
        let type = try XCTUnwrap(HealthMetric.sleep.sampleType as? HKCategoryType)
        let sample = HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                      start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(600))
        let records = try HealthSampleNormalizer.sleep([sample, sample], window: HealthSampleNormalizer.last24Hours(endingAt: now),
                                   source: { _ in self.watch })
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.id, sample.uuid)
        XCTAssertEqual(record.stage, sample.value)
        XCTAssertEqual(record.end, now)
        XCTAssertEqual(record.source, watch)
    }

    func testLast24HoursIsElapsedTimeAcrossDaylightSavingTransition() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-09T04:00:00Z"))
        let window = HealthSampleNormalizer.last24Hours(endingAt: date)
        XCTAssertEqual(window.duration, 86_400)
        XCTAssertEqual(window.end, date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let today = HealthSampleNormalizer.today(endingAt: date.addingTimeInterval(-1), calendar: calendar)
        XCTAssertEqual(today.duration, 23 * 3600 - 1) // A 23-hour local calendar day.
    }

    func testSafetyCapRejectsExactlyFullAndOverflowResults() {
        XCTAssertNoThrow(try HealthSampleNormalizer.requireComplete(sampleCount: 9999))
        for count in [10_000, 10_001] {
            XCTAssertThrowsError(try HealthSampleNormalizer.requireComplete(sampleCount: count)) {
                XCTAssertEqual($0 as? HealthDataError, .truncated)
            }
        }
    }

    func testSafetyCapIsAppliedBeforeDeduplicationOrSleepStageFiltering() throws {
        let sample = try quantitySample(.steps, unit: .count(), value: 1)
        XCTAssertThrowsError(try HealthSampleNormalizer.quantities(Array(repeating: sample, count: 10_000), metric: .steps)) {
            XCTAssertEqual($0 as? HealthDataError, .truncated)
        }
        let awake = sleepRecord(-60, 0, stage: .awake)
        XCTAssertThrowsError(try HealthSampleNormalizer.normalizedSleep(Array(repeating: awake, count: 10_000),
                                                                       window: HealthSampleNormalizer.last24Hours(endingAt: now))) {
            XCTAssertEqual($0 as? HealthDataError, .truncated)
        }
    }

    func testSourceDeduplicationKeepsDifferentVersions() {
        let newer = HealthSource(name: phone.name, bundleIdentifier: phone.bundleIdentifier, version: "2")
        XCTAssertEqual(HealthSource.sorted([phone, newer, phone]), [phone, newer])
    }

    func testConstructionAndSelectionDoNotPromptOrRead() {
        let fake = FakeHealthDataService()
        let controller = HealthKitController(service: fake)
        let _ = HealthKitView(service: fake)
        XCTAssertTrue(controller.selected.isEmpty)
        controller.setSelected(.bodyMass, enabled: true)
        XCTAssertTrue(fake.authorizationSelections.isEmpty)
        XCTAssertTrue(fake.readSelections.isEmpty)
        XCTAssertNil(controller.snapshot)
    }

    func testPermissionRequestUsesOnlySelectionAndNeverRefreshesAutomatically() async {
        let fake = FakeHealthDataService()
        let controller = HealthKitController(service: fake)
        controller.setSelected(.sleep, enabled: true)
        controller.setSelected(.bodyMass, enabled: true)
        controller.setSelected(.bodyMass, enabled: false)
        await controller.requestPermissions()?.value
        XCTAssertEqual(fake.authorizationSelections, [[.sleep]])
        XCTAssertTrue(fake.readSelections.isEmpty)
        XCTAssertNil(controller.snapshot)
        XCTAssertTrue(controller.message?.contains("不代表") == true)
        XCTAssertFalse(controller.isBusy)
    }

    func testRefreshDoesNotRequestAuthorizationAndOnlyReadsSelection() async {
        let fake = FakeHealthDataService()
        let controller = HealthKitController(service: fake)
        controller.setSelected(.steps, enabled: true)
        await controller.refresh()?.value
        XCTAssertEqual(fake.readSelections, [[.steps]])
        XCTAssertTrue(fake.authorizationSelections.isEmpty)
        XCTAssertEqual(controller.snapshot?.readings[.steps], .unavailableOrNoData)
    }

    func testFakeReadDenialAndEmptyStoreHaveSameStatusWithoutInventingZero() async {
        let fake = FakeHealthDataService()
        let controller = HealthKitController(service: fake)
        controller.setSelected(.heartRate, enabled: true)
        await controller.refresh()?.value
        let empty = controller.snapshot?.readings
        fake.simulateReadDenial = true
        await controller.requestPermissions()?.value // Success is NOT a grant.
        XCTAssertNil(controller.snapshot)
        await controller.refresh()?.value
        XCTAssertEqual(controller.snapshot?.readings, empty)
        XCTAssertEqual(controller.snapshot?.readings[.heartRate], .unavailableOrNoData)
        XCTAssertNil(controller.message)
    }

    func testActualZeroMeasurementRemainsDistinctFromMissingData() async {
        let fake = FakeHealthDataService()
        fake.nextSnapshot = HealthSnapshot(capturedAt: now, readings: [.steps: reading(0), .sleep: .unavailableOrNoData])
        let controller = HealthKitController(service: fake)
        controller.setSelected(.steps, enabled: true)
        controller.setSelected(.sleep, enabled: true)
        await controller.refresh()?.value
        XCTAssertEqual(controller.snapshot?.readings[.steps], reading(0))
        XCTAssertEqual(controller.snapshot?.readings[.sleep], .unavailableOrNoData)
    }

    func testUnavailableDeviceAndEmptySelectionNeverCallService() async {
        let fake = FakeHealthDataService()
        let controller = HealthKitController(service: fake)
        await controller.requestPermissions()?.value
        await controller.refresh()?.value
        fake.isAvailable = false
        controller.setSelected(.steps, enabled: true)
        await controller.requestPermissions()?.value
        await controller.refresh()?.value
        XCTAssertTrue(fake.readSelections.isEmpty)
        XCTAssertTrue(fake.authorizationSelections.isEmpty)
        XCTAssertEqual(controller.message, HealthDataError.unavailable.message)
        XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.isBusy)
    }

    func testAuthorizationFailureDoesNotClaimReadDenialOrExposeRawError() async {
        let fake = FakeHealthDataService()
        fake.requestError = HealthDataError.authorizationRequestFailed
        let controller = HealthKitController(service: fake)
        controller.setSelected(.steps, enabled: true)
        await controller.requestPermissions()?.value
        XCTAssertEqual(controller.message, HealthDataError.authorizationRequestFailed.message)
        XCTAssertNil(controller.snapshot)
        XCTAssertTrue(fake.readSelections.isEmpty)
    }

    func testReadErrorIsSanitizedAndTruncationDoesNotShowPartialValues() async {
        let fake = FakeHealthDataService()
        fake.readError = NSError(domain: "private.patient.example", code: 7,
                                 userInfo: [NSLocalizedDescriptionKey: "private health record"])
        let controller = HealthKitController(service: fake)
        controller.setSelected(.steps, enabled: true)
        await controller.refresh()?.value
        XCTAssertEqual(controller.message, HealthDataError.queryFailed.message)
        XCTAssertNil(controller.snapshot)
        fake.readError = nil
        fake.nextSnapshot = HealthSnapshot(capturedAt: now, readings: [.steps: .failed(.truncated)])
        await controller.refresh()?.value
        XCTAssertEqual(controller.snapshot?.readings[.steps], .failed(.truncated))
    }

    func testAlternateServiceCannotExposeUnselectedMetric() async {
        let fake = FakeHealthDataService()
        fake.nextSnapshot = HealthSnapshot(capturedAt: now, readings: [.steps: reading(), .bodyMass: reading(70)])
        let controller = HealthKitController(service: fake)
        controller.setSelected(.steps, enabled: true)
        await controller.refresh()?.value
        XCTAssertEqual(controller.snapshot?.readings.count, 1)
        XCTAssertNil(controller.snapshot?.readings[.bodyMass])
    }

    func testSelectionOffCancelsReadAndIgnoresLateSuccess() async {
        let fake = FakeHealthDataService()
        fake.suspendRead = true
        let entered = expectation(description: "read installed continuation")
        fake.readStarted = { entered.fulfill() }
        let controller = HealthKitController(service: fake)
        controller.setSelected(.steps, enabled: true)
        let operation = controller.refresh()
        await fulfillment(of: [entered], timeout: 2)
        controller.setSelected(.steps, enabled: false)
        XCTAssertTrue(operation?.isCancelled == true)
        fake.finishRead(.success(HealthSnapshot(capturedAt: now, readings: [.steps: reading()])))
        await operation?.value
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.message)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.selected.isEmpty)
    }

    func testResetIgnoresLateReadFailure() async {
        let fake = FakeHealthDataService()
        fake.suspendRead = true
        let entered = expectation(description: "read installed continuation")
        fake.readStarted = { entered.fulfill() }
        let controller = HealthKitController(service: fake)
        controller.setSelected(.bodyMass, enabled: true)
        let operation = controller.refresh()
        await fulfillment(of: [entered], timeout: 2)
        controller.reset()
        let resetMessage = controller.message
        fake.finishRead(.failure(HealthDataError.queryFailed))
        await operation?.value
        XCTAssertEqual(controller.message, resetMessage)
        XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(controller.selected.isEmpty)
    }

    func testResetIgnoresLateAuthorizationCompletion() async {
        let fake = FakeHealthDataService()
        fake.suspendAuthorization = true
        let entered = expectation(description: "authorization installed continuation")
        fake.authorizationStarted = { entered.fulfill() }
        let controller = HealthKitController(service: fake)
        controller.setSelected(.sleep, enabled: true)
        let operation = controller.requestPermissions()
        await fulfillment(of: [entered], timeout: 2)
        controller.reset()
        let resetMessage = controller.message
        fake.finishAuthorization(.success(()))
        await operation?.value
        XCTAssertEqual(controller.message, resetMessage)
        XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(fake.readSelections.isEmpty)
    }

    func testNewRefreshWinsOverOldCancellationIgnoringService() async {
        let fake = FakeHealthDataService()
        fake.suspendRead = true
        let entered = expectation(description: "first read installed continuation")
        fake.readStarted = { entered.fulfill() }
        let controller = HealthKitController(service: fake)
        controller.setSelected(.steps, enabled: true)
        let oldOperation = controller.refresh()
        await fulfillment(of: [entered], timeout: 2)
        fake.suspendRead = false
        fake.nextSnapshot = HealthSnapshot(capturedAt: now, readings: [.steps: reading(200)])
        await controller.refresh()?.value
        fake.finishRead(.success(HealthSnapshot(capturedAt: now, readings: [.steps: reading(100)])))
        await oldOperation?.value
        XCTAssertEqual(controller.snapshot?.readings[.steps], reading(200))
        XCTAssertFalse(controller.isBusy)
    }

    func testLeavingPageClearsMemoryAndIgnoresLateResult() async {
        let fake = FakeHealthDataService()
        fake.suspendRead = true
        let entered = expectation(description: "read installed continuation")
        fake.readStarted = { entered.fulfill() }
        let controller = HealthKitController(service: fake)
        controller.setSelected(.bodyMass, enabled: true)
        let operation = controller.refresh()
        await fulfillment(of: [entered], timeout: 2)
        controller.cancelAndClear()
        fake.finishRead(.success(HealthSnapshot(capturedAt: now, readings: [.bodyMass: reading(70)])))
        await operation?.value
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.message)
        XCTAssertFalse(controller.isBusy)
    }

    func testCancellationIsNotReportedAsAnErrorOrDenial() async {
        let fake = FakeHealthDataService()
        fake.readError = CancellationError()
        let controller = HealthKitController(service: fake)
        controller.setSelected(.sleep, enabled: true)
        await controller.refresh()?.value
        XCTAssertNil(controller.message)
        XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.isBusy)
    }

    func testPendingQueryCancellationStopsExactlyOnceAndIgnoresLateCallbacks() async {
        let gate = HealthKitCallbackGate<Int>()
        var executions = 0
        var stops = 0
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                gate.start(continuation, execute: { executions += 1 }, stop: {
                    stops += 1
                    gate.finish(.failure(HealthDataError.queryFailed)) // stop can provoke a callback.
                })
                gate.cancel()
                gate.cancel()
                gate.finish(.success(99))
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected, exactly one continuation resume.
        } catch {
            XCTFail("Unexpected error type")
        }
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(stops, 1)
    }

    func testCancellationBeforeRegistrationDoesNotExecuteOrStopQuery() async {
        let gate = HealthKitCallbackGate<Int>()
        var executions = 0
        var stops = 0
        gate.cancel()
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                gate.start(continuation, execute: { executions += 1 }, stop: { stops += 1 })
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error type")
        }
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(stops, 0)
    }

    func testSynchronousCompletionWinsAndCompletedQueryIsNotStopped() async throws {
        let gate = HealthKitCallbackGate<Int>()
        var stops = 0
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            gate.start(continuation, execute: { gate.finish(.success(7)) }, stop: { stops += 1 })
            gate.finish(.success(8))
            gate.cancel()
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(stops, 0)
    }

    func testCallbackFailureWinsAndLaterCancelDoesNotStopCompletedQuery() async {
        let gate = HealthKitCallbackGate<Int>()
        var stops = 0
        do {
            let _: Int = try await withCheckedThrowingContinuation { continuation in
                gate.start(continuation, execute: { gate.finish(.failure(HealthDataError.queryFailed)) }, stop: { stops += 1 })
                gate.cancel()
            }
            XCTFail("Expected query failure")
        } catch {
            XCTAssertEqual(error as? HealthDataError, .queryFailed)
        }
        XCTAssertEqual(stops, 0)
    }
}
