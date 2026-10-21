// iOS 17+, Swift 5. Read-only, foreground HealthKit access. No persistence or networking.
import Foundation
import HealthKit

enum HealthMetric: String, CaseIterable, Identifiable, Sendable {
    case steps, activeEnergy, exerciseMinutes, heartRate, restingHeartRate, bodyMass, sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steps: return "步数"
        case .activeEnergy: return "活动能量"
        case .exerciseMinutes: return "锻炼时间"
        case .heartRate: return "心率"
        case .restingHeartRate: return "静息心率"
        case .bodyMass: return "体重"
        case .sleep: return "睡眠"
        }
    }

    var unitLabel: String {
        switch self {
        case .steps: return "步"
        case .activeEnergy: return "kcal"
        case .exerciseMinutes, .sleep: return "分钟"
        case .heartRate, .restingHeartRate: return "次/分钟"
        case .bodyMass: return "kg"
        }
    }

    var isCumulative: Bool {
        self == .steps || self == .activeEnergy || self == .exerciseMinutes
    }

    var quantityIdentifier: HKQuantityTypeIdentifier? {
        switch self {
        case .steps: return .stepCount
        case .activeEnergy: return .activeEnergyBurned
        case .exerciseMinutes: return .appleExerciseTime
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .bodyMass: return .bodyMass
        case .sleep: return nil
        }
    }

    var sampleType: HKSampleType? {
        if let quantityIdentifier {
            return HKObjectType.quantityType(forIdentifier: quantityIdentifier)
        }
        return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    }

    var quantityUnit: HKUnit? {
        switch self {
        case .steps: return .count()
        case .activeEnergy: return .kilocalorie()
        case .exerciseMinutes: return .minute()
        case .heartRate, .restingHeartRate: return HKUnit.count().unitDivided(by: .minute())
        case .bodyMass: return .gramUnit(with: .kilo)
        case .sleep: return nil
        }
    }
}

// Deliberately excludes device identifiers, HealthKit metadata, and raw error text.
struct HealthDevice: Hashable, Sendable {
    let name: String?
    let manufacturer: String?
    let model: String?
    let hardwareVersion: String?
    let firmwareVersion: String?
    let softwareVersion: String?

    init(_ device: HKDevice) {
        name = device.name
        manufacturer = device.manufacturer
        model = device.model
        hardwareVersion = device.hardwareVersion
        firmwareVersion = device.firmwareVersion
        softwareVersion = device.softwareVersion
    }

    var description: String {
        [name, manufacturer, model, hardwareVersion, firmwareVersion, softwareVersion]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct HealthSource: Hashable, Sendable {
    let name: String
    let bundleIdentifier: String
    let version: String?
    let device: HealthDevice?

    init(name: String, bundleIdentifier: String, version: String? = nil, device: HealthDevice? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.device = device
    }

    init(sample: HKSample) {
        // Only retrieved samples have a sourceRevision. Offline, unsaved sample
        // fixtures must inject a source into the normalizer instead.
        self.init(revision: sample.sourceRevision, device: sample.device)
    }

    init(revision: HKSourceRevision, device: HKDevice?) {
        self.init(name: revision.source.name, bundleIdentifier: revision.source.bundleIdentifier,
                  version: revision.version, device: device.map { HealthDevice($0) })
    }

    static func sorted(_ sources: [HealthSource]) -> [HealthSource] {
        Array(Set(sources)).sorted {
            let lhs = [$0.bundleIdentifier, $0.name, $0.version ?? "", $0.device?.description ?? ""]
            let rhs = [$1.bundleIdentifier, $1.name, $1.version ?? "", $1.device?.description ?? ""]
            return lhs.lexicographicallyPrecedes(rhs)
        }
    }
}

struct HealthQuantityRecord: Identifiable, Equatable, Sendable {
    let id: UUID // Original HealthKit UUID, never a newly generated identifier.
    let start: Date
    let end: Date
    let value: Double
    let source: HealthSource
}

struct HealthSleepRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let stage: Int
    let source: HealthSource
}

struct HealthMeasurement: Equatable, Sendable {
    let value: Double
    let interval: DateInterval
    let sources: [HealthSource]
    // Provenance only. NEVER sum quantitySamples to calculate cumulative values.
    let quantitySamples: [HealthQuantityRecord]
    let sleepSamples: [HealthSleepRecord]
}

enum HealthDataError: Error, Equatable, Sendable {
    case unavailable, authorizationRequestFailed, queryFailed, truncated, invalidData

    var message: String {
        switch self {
        case .unavailable: return "此设备无法使用健康数据。"
        case .authorizationRequestFailed: return "未能完成权限请求。请检查系统健康设置后重试；这不表示读取权限被拒绝。"
        case .queryFailed: return "暂时无法读取健康数据，请稍后重试。"
        case .truncated: return "记录达到 10,000 条安全上限，无法确认结果完整，未显示部分结果。"
        case .invalidData: return "健康数据格式或单位不符合预期，未显示该结果。"
        }
    }

    static func sanitized(_ error: Error) -> HealthDataError {
        (error as? HealthDataError) ?? .queryFailed
    }
}

enum HealthReading: Equatable, Sendable {
    case value(HealthMeasurement)
    // HealthKit intentionally does not reveal whether reading was denied.
    case unavailableOrNoData
    case failed(HealthDataError)
}

struct HealthSnapshot: Equatable, Sendable {
    let capturedAt: Date
    let readings: [HealthMetric: HealthReading]
}

@MainActor
protocol HealthDataService: AnyObject {
    var isAvailable: Bool { get }
    // Completion means only that the request flow completed, NOT that reads were granted.
    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws
    func read(_ metrics: Set<HealthMetric>, now: Date) async throws -> HealthSnapshot
}

// Pure normalization helpers also allow offline tests without an HKHealthStore.
enum HealthSampleNormalizer {
    static let sampleLimit = 10_000

    static func requireComplete(sampleCount: Int) throws {
        // Query exactly this many, not HKObjectQueryNoLimit or a 10,001st sentinel.
        // At the cap even an exactly-full result is conservatively rejected: there
        // might be more records. Check BEFORE filtering or UUID deduplication.
        guard sampleCount < sampleLimit else { throw HealthDataError.truncated }
    }

    static func last24Hours(endingAt now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-86_400), end: now)
    }

    static func today(endingAt now: Date, calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: calendar.startOfDay(for: now), end: now)
    }

    static func converted(_ quantity: HKQuantity, metric: HealthMetric) throws -> Double {
        guard let unit = metric.quantityUnit, quantity.is(compatibleWith: unit) else {
            throw HealthDataError.invalidData
        }
        let value = quantity.doubleValue(for: unit)
        guard value.isFinite, value >= 0 else { throw HealthDataError.invalidData }
        return value
    }

    static func quantities(_ samples: [HKQuantitySample], metric: HealthMetric,
                           source: (HKSample) -> HealthSource = { HealthSource(sample: $0) }) throws -> [HealthQuantityRecord] {
        try requireComplete(sampleCount: samples.count)
        var seen = Set<UUID>()
        return try samples.filter { seen.insert($0.uuid).inserted }.map { sample in
            guard sample.quantityType.identifier == metric.quantityIdentifier?.rawValue,
                  sample.endDate >= sample.startDate else { throw HealthDataError.invalidData }
            return HealthQuantityRecord(id: sample.uuid, start: sample.startDate, end: sample.endDate,
                                        value: try converted(sample.quantity, metric: metric),
                                        source: source(sample))
        }.sorted {
            if $0.end != $1.end { return $0.end > $1.end }
            if $0.start != $1.start { return $0.start > $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func sleep(_ samples: [HKCategorySample], window: DateInterval,
                      source: (HKSample) -> HealthSource = { HealthSource(sample: $0) }) throws -> [HealthSleepRecord] {
        try requireComplete(sampleCount: samples.count)
        let records = try samples.map { sample -> HealthSleepRecord in
            guard sample.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue else {
                throw HealthDataError.invalidData
            }
            return HealthSleepRecord(id: sample.uuid, start: sample.startDate, end: sample.endDate,
                                     stage: sample.value, source: source(sample))
        }
        return try normalizedSleep(records, window: window)
    }

    static func normalizedSleep(_ records: [HealthSleepRecord], window: DateInterval) throws -> [HealthSleepRecord] {
        try requireComplete(sampleCount: records.count)
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        var seen = Set<UUID>()
        return records.compactMap { record -> HealthSleepRecord? in
            guard seen.insert(record.id).inserted, asleep.contains(record.stage) else { return nil }
            let start = max(record.start, window.start)
            let end = min(record.end, window.end)
            guard start < end else { return nil }
            return HealthSleepRecord(id: record.id, start: start, end: end,
                                     stage: record.stage, source: record.source)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func asleepMinutes(_ records: [HealthSleepRecord]) -> Double {
        // Union across ALL sources/stages. No source priority guesses or overlap sums.
        let intervals = records.filter { $0.start < $0.end }.sorted { $0.start < $1.start }
        guard let first = intervals.first else { return 0 }
        var start = first.start
        var end = first.end
        var seconds: TimeInterval = 0
        for record in intervals.dropFirst() {
            if record.start <= end {
                end = max(end, record.end)
            } else {
                seconds += end.timeIntervalSince(start)
                start = record.start
                end = record.end
            }
        }
        return (seconds + end.timeIntervalSince(start)) / 60
    }
}

// Synchronizes callback completion, cancellation-before-start, and cancellation
// racing execute(). The recursive lock permits a synchronous test callback.
// Each started, still-pending query is stopped exactly once on cancellation;
// a completed or never-started query is not stopped. Late callbacks are ignored.
final class HealthKitCallbackGate<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var terminal: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var stop: (() -> Void)?

    func start(_ continuation: CheckedContinuation<Value, Error>,
               execute: () -> Void, stop: @escaping () -> Void) {
        lock.lock()
        if let terminal {
            lock.unlock()
            continuation.resume(with: terminal)
            return
        }
        self.continuation = continuation
        self.stop = stop
        // Keep registration AND execute ordered ahead of a racing stop.
        execute()
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        resolve(result, cancelling: false)
    }

    func cancel() {
        resolve(.failure(CancellationError()), cancelling: true)
    }

    private func resolve(_ result: Result<Value, Error>, cancelling: Bool) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        let pending = continuation
        let stopQuery = cancelling ? stop : nil
        continuation = nil
        stop = nil
        lock.unlock()
        stopQuery?()
        pending?.resume(with: result)
    }
}

@MainActor
final class HealthKitService: HealthDataService {
    private lazy var store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestReadAuthorization(for metrics: Set<HealthMetric>) async throws {
        try Task.checkCancellation()
        guard !metrics.isEmpty else { return }
        guard isAvailable else { throw HealthDataError.unavailable }
        let types = try Set(metrics.map { metric -> HKObjectType in
            guard let type = metric.sampleType else { throw HealthDataError.unavailable }
            return type
        })
        let gate = HealthKitCallbackGate<Void>()
        let store = self.store
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.start(continuation, execute: {
                    store.requestAuthorization(toShare: [], read: types) { completed, error in
                        if error != nil || !completed {
                            gate.finish(.failure(HealthDataError.authorizationRequestFailed))
                        } else {
                            gate.finish(.success(()))
                        }
                    }
                }, stop: {
                    // Apple provides no API to dismiss an authorization sheet.
                    // Cancellation detaches our waiter; the eventual callback is ignored.
                })
            }
        } onCancel: {
            gate.cancel()
        }
        try Task.checkCancellation()
        // Never call authorizationStatus(for:): it describes WRITE permission.
    }

    func read(_ metrics: Set<HealthMetric>, now: Date = Date()) async throws -> HealthSnapshot {
        try Task.checkCancellation()
        guard !metrics.isEmpty else { return HealthSnapshot(capturedAt: now, readings: [:]) }
        guard isAvailable else { throw HealthDataError.unavailable }
        var readings: [HealthMetric: HealthReading] = [:]
        for metric in HealthMetric.allCases where metrics.contains(metric) {
            try Task.checkCancellation()
            do {
                if metric == .sleep {
                    readings[metric] = try await readSleep(now: now)
                } else if metric.isCumulative {
                    readings[metric] = try await readCumulative(metric, now: now)
                } else {
                    readings[metric] = try await readLatest(metric, now: now)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                readings[metric] = .failed(HealthDataError.sanitized(error))
            }
        }
        try Task.checkCancellation()
        return HealthSnapshot(capturedAt: now, readings: readings)
    }

    private func query<Value>(_ makeQuery: (@escaping (Result<Value, Error>) -> Void) -> HKQuery) async throws -> Value {
        let gate = HealthKitCallbackGate<Value>()
        let store = self.store
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let query = makeQuery { gate.finish($0) }
                gate.start(continuation, execute: { store.execute(query) }, stop: { store.stop(query) })
            }
        } onCancel: {
            gate.cancel()
        }
        try Task.checkCancellation()
        return value
    }

    private func samples(type: HKSampleType, predicate: NSPredicate, latestOnly: Bool = false) async throws -> [HKSample] {
        let result: [HKSample] = try await query { finish in
            HKSampleQuery(sampleType: type, predicate: predicate,
                          limit: latestOnly ? 1 : HealthSampleNormalizer.sampleLimit,
                          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false),
                                            NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) {
                _, samples, error in
                if error != nil { finish(.failure(HealthDataError.queryFailed)) }
                else { finish(.success(samples ?? [])) }
            }
        }
        // A top-one query deliberately returns only the latest measurement, not
        // a partial history. All queries used for totals/provenance enforce the cap.
        if !latestOnly { try HealthSampleNormalizer.requireComplete(sampleCount: result.count) }
        return result
    }

    private func statistics(type: HKQuantityType, predicate: NSPredicate,
                            options: HKStatisticsOptions) async throws -> HKStatistics? {
        try await query { finish in
            HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                              options: options) { _, statistics, error in
                if error != nil { finish(.failure(HealthDataError.queryFailed)) }
                else { finish(.success(statistics)) }
            }
        }
    }

    private func readCumulative(_ metric: HealthMetric, now: Date) async throws -> HealthReading {
        guard let type = metric.sampleType as? HKQuantityType else { throw HealthDataError.unavailable }
        let window = HealthSampleNormalizer.today(endingAt: now)
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: .strictStartDate)
        // Keep the total's query strictly cumulativeSum so HealthKit owns source
        // merging. Separate-by-source statistics below are for provenance ONLY.
        let combined = try await statistics(type: type, predicate: predicate, options: .cumulativeSum)
        guard let sum = combined?.sumQuantity() else { return .unavailableOrNoData }
        let value = try HealthSampleNormalizer.converted(sum, metric: metric)
        let provenance = try await statistics(type: type, predicate: predicate,
                                              options: [.cumulativeSum, .separateBySource])
        let raw = try await samples(type: type, predicate: predicate)
        guard let quantities = raw as? [HKQuantitySample] else { throw HealthDataError.invalidData }
        let records = try HealthSampleNormalizer.quantities(quantities, metric: metric)
        // Statistics exposes contributing source identities; samples supply their
        // revisions/devices. Do not pretend to know per-device allocation of the total.
        let contributors = provenance?.sources ?? []
        let bundles = Set(contributors.map { $0.bundleIdentifier })
        let matchingRecords = records.filter { bundles.contains($0.source.bundleIdentifier) }
        var sources = matchingRecords.map { $0.source }
        for source in contributors where !sources.contains(where: { $0.bundleIdentifier == source.bundleIdentifier }) {
            sources.append(HealthSource(name: source.name, bundleIdentifier: source.bundleIdentifier))
        }
        return .value(HealthMeasurement(value: value, interval: window, sources: HealthSource.sorted(sources),
                                        quantitySamples: matchingRecords, sleepSamples: []))
    }

    private func readLatest(_ metric: HealthMetric, now: Date) async throws -> HealthReading {
        guard let type = metric.sampleType as? HKQuantityType else { throw HealthDataError.unavailable }
        let predicate = HKQuery.predicateForSamples(withStart: nil, end: now, options: .strictEndDate)
        let raw = try await samples(type: type, predicate: predicate, latestOnly: true)
        guard let quantities = raw as? [HKQuantitySample] else { throw HealthDataError.invalidData }
        guard let record = try HealthSampleNormalizer.quantities(quantities, metric: metric).first else {
            return .unavailableOrNoData
        }
        return .value(HealthMeasurement(value: record.value, interval: DateInterval(start: record.start, end: record.end),
                                        sources: [record.source], quantitySamples: [record], sleepSamples: []))
    }

    private func readSleep(now: Date) async throws -> HealthReading {
        guard let type = HealthMetric.sleep.sampleType else { throw HealthDataError.unavailable }
        let window = HealthSampleNormalizer.last24Hours(endingAt: now)
        // No strict boundary flags: include samples crossing either window edge.
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let raw = try await samples(type: type, predicate: predicate)
        guard let categories = raw as? [HKCategorySample] else { throw HealthDataError.invalidData }
        let records = try HealthSampleNormalizer.sleep(categories, window: window)
        guard !records.isEmpty else { return .unavailableOrNoData }
        return .value(HealthMeasurement(value: HealthSampleNormalizer.asleepMinutes(records), interval: window,
                                        sources: HealthSource.sorted(records.map { $0.source }),
                                        quantitySamples: [], sleepSamples: records))
    }
}
