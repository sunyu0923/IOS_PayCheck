// Deterministic evaluation plus isolated SwiftData integration tests. Requires iOS 17.
// These tests must run on an Apple SDK host, not the Windows authoring machine.
import Foundation
import SwiftData
import XCTest
@testable import GoalPet

@MainActor final class GoalRewardEngineTests: XCTestCase {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private var now: Date { date(21) }

    private func evaluate(_ data: AppSnapshot) -> GoalEvaluation {
        GoalEngine.evaluate(data, now: now, calendar: utc)
    }

    private func savings(initial: Int64 = 0, target: Int64 = 1_000,
                         family: UUID? = nil) -> SavingsGoal {
        let goal = SavingsGoal(name: "Plan", target: target, initial: initial,
                               currency: "CNY", targetDate: date(30), familyGroupID: family)
        goal.createdAt = date(1)
        return goal
    }

    private func contribution(_ goal: SavingsGoal, _ amount: Int64,
                              day: Int = 20, member: UUID? = nil) -> SavingsContribution {
        SavingsContribution(goalID: goal.id, memberID: member, signedMinor: amount,
                            date: date(day), note: "")
    }

    private func transaction(day: Int = 21) -> LedgerTransaction {
        let record = LedgerTransaction(kind: .expense, amount: 100, currency: "CNY",
            category: "餐饮", accountID: UUID(), date: date(day), note: "")
        record.createdAt = date(day)
        return record
    }

    private func meal(_ mode: FoodRecognitionMode, day: Int = 21) throws -> FoodRecord {
        var draft = EditableFoodItem()
        draft.name = "Rice"
        let confirmed = try ConfirmedFoodMeal.confirm(id: UUID(), mealType: .lunch,
            date: date(day), source: mode, drafts: [draft], userConfirmed: true, now: date(30))
        let record = FoodRecord(meal: confirmed, confirmedAt: date(day))
        record.items = confirmed.foods.map { FoodItem(value: $0) }
        return record
    }

    private func weight(_ kg: Double, day: Int = 21) -> WeightRecord {
        WeightRecord(kilograms: kg, date: date(day), note: "")
    }

    private func health(kind: HealthGoalKind = .lose, start: Double = 80,
                        target: Double? = 60) -> HealthGoal {
        let goal = HealthGoal(kind: kind, start: start, target: target)
        goal.startDate = date(1)
        return goal
    }

    private func adult() -> UserProfile {
        let profile = UserProfile()
        profile.dateOfBirth = utc.date(from: DateComponents(year: 2000, month: 1, day: 1))!
        return profile
    }

    private func healthData(_ goal: HealthGoal, kg: Double = 70) -> AppSnapshot {
        AppSnapshot(profiles: [adult()], weights: [weight(kg, day: 19), weight(kg, day: 20), weight(kg)],
                    healthGoals: [goal])
    }

    private func context() throws -> ModelContext {
        let schema = Schema([RewardEvent.self, SavingsGoal.self, SavingsContribution.self, WeightRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func events(_ context: ModelContext) throws -> [RewardEvent] {
        var descriptor = FetchDescriptor<RewardEvent>()
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    private func award(_ key: String = "test", xp: Int = 20) -> RewardCandidate {
        RewardCandidate(key: key, title: "Award", xp: xp)
    }

    func testEmptySnapshotHasThreeIncompleteUTCTasks() {
        let result = evaluate(AppSnapshot())
        XCTAssertEqual(result.tasks.count, 3)
        XCTAssertTrue(result.tasks.allSatisfy { !$0.isComplete && $0.title.contains("UTC") })
        XCTAssertTrue(result.milestones.isEmpty)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testThreeDailyTasksAwardTenXPEach() throws {
        let data = AppSnapshot(transactions: [transaction()], weights: [weight(70)], meals: [try meal(.manual)])
        let result = evaluate(data)
        XCTAssertTrue(result.tasks.allSatisfy(\.isComplete))
        XCTAssertEqual(result.candidates.map(\.xp), [10, 10, 10])
        XCTAssertTrue(result.candidates.allSatisfy { $0.sourceKey != nil && $0.petID == nil })
    }

    func testFinanceIgnoresDeletedInvalidAndFutureRecords() {
        let deleted = transaction()
        deleted.deletedAt = now
        let zero = transaction()
        zero.amountMinor = 0
        let invalid = transaction()
        invalid.kindRaw = "unknown"
        let unsupported = transaction()
        unsupported.currency = "UNKNOWN"
        let data = AppSnapshot(transactions: [deleted, zero, invalid, unsupported, transaction(day: 22)])
        XCTAssertFalse(evaluate(data).tasks[0].isComplete)
        XCTAssertTrue(evaluate(data).candidates.isEmpty)
    }

    func testManualAndRemoteMealsEachQualifyWithoutCalorieTargets() throws {
        for mode in [FoodRecognitionMode.manual, .remote] {
            let result = evaluate(AppSnapshot(meals: [try meal(mode)]))
            XCTAssertTrue(result.tasks[1].isComplete)
            XCTAssertEqual(result.candidates.map(\.xp), [10])
        }
    }

    func testMockEmptyUnknownAndFutureMealsDoNotQualify() throws {
        let empty = try meal(.manual)
        empty.items = []
        let unknown = try meal(.manual)
        unknown.sourceRaw = "unknown"
        let notConfirmed = try meal(.remote)
        notConfirmed.confirmedAt = date(22)
        let data = AppSnapshot(meals: [try meal(.mock), empty, unknown, notConfirmed, try meal(.manual, day: 22)])
        XCTAssertFalse(evaluate(data).tasks[1].isComplete)
    }

    func testInvalidWeightsDoNotQualifyButLoggingDoesNotRequireAnAdult() {
        let invalid = [Double.nan, .infinity, -1, 0, 9, 501].map { weight($0) }
        XCTAssertFalse(evaluate(AppSnapshot(weights: invalid + [weight(70, day: 22)])).tasks[2].isComplete)
        XCTAssertTrue(evaluate(AppSnapshot(weights: [weight(20)])).tasks[2].isComplete)
    }

    func testManyRecordsStillProduceOnlyOneCandidatePerTask() throws {
        let data = AppSnapshot(transactions: [transaction(), transaction()],
            weights: [weight(70), weight(70), weight(71)], meals: [try meal(.manual), try meal(.remote)])
        let result = evaluate(data)
        XCTAssertEqual(result.candidates.count, 3)
        XCTAssertEqual(Set(result.candidates.map(\.key)).count, 3)
    }

    func testTimeZoneAndCalendarChangesCannotReplayDailyKeys() {
        var west = Calendar(identifier: .buddhist)
        west.timeZone = TimeZone(secondsFromGMT: -12 * 3_600)!
        var east = Calendar(identifier: .gregorian)
        east.timeZone = TimeZone(secondsFromGMT: 14 * 3_600)!
        let instant = date(21, hour: 0)
        let record = transaction()
        record.date = instant
        let data = AppSnapshot(transactions: [record])
        let a = GoalEngine.evaluate(data, now: instant, calendar: west)
        let b = GoalEngine.evaluate(data, now: instant, calendar: east)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.candidates.first?.key, "daily:finance:2026-10-21")
    }

    func testUTCMidnightExcludesYesterdayAndFutureSameDay() {
        let record = transaction()
        record.date = date(21, hour: 0).addingTimeInterval(-1)
        let future = transaction()
        future.date = date(21, hour: 0).addingTimeInterval(1)
        let result = GoalEngine.evaluate(AppSnapshot(transactions: [record, future]),
                                        now: date(21, hour: 0), calendar: utc)
        XCTAssertFalse(result.tasks[0].isComplete)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testEarnedDailyKeyDoesNotHideCurrentTaskOrAwardAgain() throws {
        var data = AppSnapshot(weights: [weight(70)])
        let candidate = try XCTUnwrap(evaluate(data).candidates.first)
        data.rewards = [RewardEvent(key: candidate.key, title: candidate.title, xp: 10, earnedAt: now)]
        let result = evaluate(data)
        XCTAssertTrue(result.tasks[2].isComplete)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testSavingsHasFourStableStagesAndTwentyXPEach() {
        let goal = savings()
        let result = evaluate(AppSnapshot(goals: [goal], contributions: [contribution(goal, 1_000)]))
        XCTAssertEqual(result.milestones.map(\.percentage), [25, 50, 75, 100])
        XCTAssertTrue(result.milestones.allSatisfy(\.isReached))
        XCTAssertEqual(result.candidates.map(\.xp), [20, 20, 20, 20])
        XCTAssertEqual(result.candidates.map(\.key), result.milestones.map(\.id))
        XCTAssertTrue(result.candidates.allSatisfy { $0.key.contains(goal.id.uuidString.lowercased()) })
    }

    func testInitialSeedAloneShowsProgressButNeverAwards() {
        let goal = savings(initial: 1_000)
        let result = evaluate(AppSnapshot(goals: [goal]))
        XCTAssertTrue(result.milestones.allSatisfy(\.isReached))
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testSeedIsExcludedFromFullTargetRewardThresholds() {
        let goal = savings(initial: 750)
        let result = evaluate(AppSnapshot(goals: [goal], contributions: [contribution(goal, 250)]))
        XCTAssertTrue(result.milestones.allSatisfy(\.isReached))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.key, result.milestones[0].id)
    }

    func testWithdrawalsReduceEligibleNetRatherThanGrossDeposits() {
        let goal = savings()
        let result = evaluate(AppSnapshot(goals: [goal], contributions: [
            contribution(goal, 1_000), contribution(goal, -750)
        ]))
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.milestones.filter(\.isReached).map(\.percentage), [25])
    }

    func testPreCreationContributionsDisplayButDoNotAward() {
        let goal = savings()
        goal.createdAt = date(20)
        let result = evaluate(AppSnapshot(goals: [goal], contributions: [contribution(goal, 1_000, day: 19)]))
        XCTAssertTrue(result.milestones.allSatisfy(\.isReached))
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testDeletedFutureAndOtherGoalContributionsAreIgnored() {
        let goal = savings()
        let deleted = contribution(goal, 1_000)
        deleted.deletedAt = now
        let result = evaluate(AppSnapshot(goals: [goal], contributions: [deleted,
            contribution(goal, 1_000, day: 22), contribution(savings(), 1_000)]))
        XCTAssertTrue(result.milestones.allSatisfy { !$0.isReached })
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testFamilyAndMemberContributionsNeverEarnPersonalMilestoneXP() {
        let family = savings(family: UUID())
        let personal = savings()
        let result = evaluate(AppSnapshot(goals: [family, personal], contributions: [
            contribution(family, 1_000), contribution(personal, 1_000, member: UUID())
        ]))
        XCTAssertEqual(result.milestones.count, 8)
        XCTAssertTrue(result.milestones.allSatisfy(\.isReached))
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testPausedSavingsStillShowsProgressAndIndependentDailyTasks() {
        let goal = savings()
        goal.statusRaw = "paused"
        let result = evaluate(AppSnapshot(transactions: [transaction()], goals: [goal],
            contributions: [contribution(goal, 1_000)]))
        XCTAssertTrue(result.milestones.allSatisfy { $0.isPaused && $0.isReached })
        XCTAssertEqual(result.candidates.map(\.key), [result.tasks[0].id])
    }

    func testInvalidTargetsAndFutureGoalsCannotReachStages() {
        for target in [Int64(0), Int64(-1)] {
            let goal = savings(initial: 1_000, target: target)
            XCTAssertTrue(evaluate(AppSnapshot(goals: [goal])).milestones.allSatisfy { !$0.isReached })
        }
        let future = savings(initial: 1_000)
        future.createdAt = date(22)
        XCTAssertTrue(evaluate(AppSnapshot(goals: [future])).milestones.allSatisfy { !$0.isReached })
    }

    func testExactSavingsThresholdDoesNotRoundUpOrOverflow() {
        let goal = savings(target: Int64.max)
        let quarter = Int64.max / 4
        var data = AppSnapshot(goals: [goal], contributions: [contribution(goal, quarter)])
        XCTAssertTrue(evaluate(data).candidates.isEmpty)
        data.contributions.append(contribution(goal, 1))
        XCTAssertEqual(evaluate(data).candidates.count, 1)
        data.contributions.append(contribution(goal, Int64.max))
        XCTAssertEqual(evaluate(data).candidates.count, 4)
    }

    func testSavingsEditsDoNotCreateNewStageIdentities() {
        let goal = savings()
        let data = AppSnapshot(goals: [goal], contributions: [contribution(goal, 1_000)])
        let before = evaluate(data).candidates.map(\.key)
        goal.name = "Renamed"
        goal.updatedAt = date(22)
        goal.targetDate = date(31)
        goal.targetMinor = 500
        XCTAssertEqual(evaluate(data).candidates.map(\.key), before)
    }

    func testAdultLossAndGainUseThreeDayAverageWithoutMilestoneXP() {
        for goal in [health(), health(kind: .gain, start: 60, target: 80)] {
            let result = evaluate(healthData(goal))
            XCTAssertEqual(result.milestones.filter(\.isReached).map(\.percentage), [25, 50])
            XCTAssertEqual(result.candidates.map(\.xp), [10])
            XCTAssertTrue(result.candidates.allSatisfy { $0.key.hasPrefix("daily:weight:") })
        }
    }

    func testMinorAndUnknownAgeDoNotGetWeightMilestones() {
        var data = healthData(health())
        data.profiles = []
        XCTAssertTrue(evaluate(data).milestones.isEmpty)
        let minor = adult()
        minor.dateOfBirth = utc.date(from: DateComponents(year: 2010, month: 1, day: 1))!
        data.profiles = [minor]
        XCTAssertTrue(evaluate(data).milestones.isEmpty)
        XCTAssertTrue(evaluate(data).tasks[2].isComplete)
        minor.dateOfBirth = nil
        XCTAssertTrue(evaluate(data).milestones.isEmpty)
    }

    func testEighteenthBirthdayIsEligible() {
        var data = healthData(health())
        let profile = adult()
        profile.dateOfBirth = utc.date(from: DateComponents(year: 2008, month: 10, day: 21))!
        data.profiles = [profile]
        XCTAssertEqual(evaluate(data).milestones.count, 4)
        profile.dateOfBirth = utc.date(from: DateComponents(year: 2008, month: 10, day: 22))!
        XCTAssertTrue(evaluate(data).milestones.isEmpty)
    }

    func testNonDirectionalAndInvalidHealthTargetsHaveNoMilestones() {
        let goals = [health(kind: .record, target: nil), health(kind: .maintain, target: nil),
                     health(target: 90), health(kind: .gain, target: 60), health(target: 80),
                     health(target: .nan), health(start: .infinity), health(target: 20)]
        for goal in goals { XCTAssertTrue(evaluate(healthData(goal)).milestones.isEmpty) }
    }

    func testDuplicateWeightsCannotSatisfyThreeDistinctDayRequirement() {
        var data = healthData(health(), kg: 60)
        data.weights = [weight(60), weight(60), weight(60), weight(60, day: 20)]
        let result = evaluate(data)
        XCTAssertTrue(result.milestones.allSatisfy { !$0.isReached })
        XCTAssertEqual(result.candidates.count, 1)
    }

    func testRollingAverageWeightsDaysEquallyDespiteDuplicateSamples() {
        var data = healthData(health())
        data.weights = [weight(80, day: 19), weight(70, day: 20)] + (0..<20).map { _ in weight(60) }
        XCTAssertEqual(evaluate(data).milestones.filter(\.isReached).map(\.percentage), [25, 50])
    }

    func testHealthRequiresPostStartWeightsAndDoesNotFallbackToOldLatest() {
        let goal = health()
        goal.startDate = date(21)
        let result = evaluate(healthData(goal, kg: 60))
        XCTAssertTrue(result.milestones.allSatisfy { !$0.isReached })
    }

    func testHealthWindowExcludesOldFutureAndInvalidMeasurements() {
        var data = healthData(health(), kg: 60)
        data.weights = [weight(60, day: 14), weight(60, day: 20), weight(60),
                        weight(60, day: 22), weight(.nan, day: 19), weight(20, day: 18)]
        XCTAssertTrue(evaluate(data).milestones.allSatisfy { !$0.isReached })
        data.weights.append(weight(60, day: 15))
        XCTAssertTrue(evaluate(data).milestones.allSatisfy(\.isReached))
    }

    func testPausedHealthDoesNotDisableSafeLogging() {
        let goal = health()
        goal.statusRaw = "paused"
        let result = evaluate(healthData(goal, kg: 60))
        XCTAssertTrue(result.milestones.allSatisfy { $0.isPaused && $0.isReached })
        XCTAssertEqual(result.candidates.map(\.xp), [10])
    }

    func testHealthStageIdentityUsesUUIDNotStartDateOrUpdatedAt() {
        let goal = health()
        let data = healthData(goal)
        let before = evaluate(data).milestones.map(\.id)
        goal.startDate = date(2)
        goal.updatedAt = date(21)
        goal.targetKG = 65
        XCTAssertEqual(evaluate(data).milestones.map(\.id), before)
        XCTAssertTrue(before.allSatisfy { $0.contains(goal.id.uuidString.lowercased()) })
    }

    func testWeightAmountAndSpeedDoNotChangeDailyXP() {
        let slow = evaluate(healthData(health(), kg: 79))
        let fast = evaluate(healthData(health(), kg: 60))
        XCTAssertNotEqual(slow.milestones.map(\.isReached), fast.milestones.map(\.isReached))
        XCTAssertEqual(slow.candidates.map(\.xp), fast.candidates.map(\.xp))
    }

    func testUnderweightTargetIsNotPresentedAsProgress() {
        let data = healthData(health(target: 40))
        data.profiles[0].heightCM = 180
        XCTAssertTrue(evaluate(data).milestones.isEmpty)
    }

    func testReconcileIsIdempotentBeforeAndAfterSaving() throws {
        let context = try context()
        try RewardEngine.reconcile([award()], in: context, now: now)
        try RewardEngine.reconcile([award()], in: context, now: date(22))
        XCTAssertEqual(try events(context).count, 2) // XP plus cat unlock.
        try context.save()
        try RewardEngine.reconcile([award()], in: context, now: date(23))
        XCTAssertEqual(RewardEngine.experience(try events(context)), 20)
        XCTAssertEqual(try events(context).first { $0.key == "test" }?.earnedAt, now)
    }

    func testReopenedContextNeverUpsertsExistingAward() throws {
        let original = try context()
        try RewardEngine.reconcile([award()], in: original, now: now)
        try original.save()
        let reopened = ModelContext(original.container)
        reopened.autosaveEnabled = false
        let changed = RewardCandidate(key: "test", title: "Changed", xp: 999, petID: "bird")
        try RewardEngine.reconcile([changed], in: reopened, now: date(22))
        let values = try events(reopened)
        let event = try XCTUnwrap(values.first { $0.key == "test" })
        XCTAssertEqual(event.title, "Award")
        XCTAssertEqual(event.xp, 20)
        XCTAssertNil(event.petID)
        XCTAssertEqual(event.earnedAt, now)
        XCTAssertEqual(RewardEngine.unlockedPetIDs(values), Set(["cat"]))
    }

    func testDuplicateCandidatesInOneBatchAwardOnlyOnce() throws {
        let context = try context()
        try RewardEngine.reconcile([award(), award(), award()], in: context, now: now)
        XCTAssertEqual(RewardEngine.experience(try events(context)), 20)
        XCTAssertEqual(try events(context).count, 2)
    }

    func testPetThresholdsAreInclusiveDeterministicAndCatalogBacked() throws {
        let catalog = Set(PetCatalog.all.map(\.id))
        for (xp, expected) in [(19, Set<String>()), (20, Set(["cat"])),
                               (99, Set(["cat"])), (100, Set(["cat", "whale"])),
                               (249, Set(["cat", "whale"])), (250, Set(["cat", "whale", "bird"]))] {
            let context = try context()
            try RewardEngine.reconcile([award(xp: xp)], in: context, now: now)
            let values = try events(context)
            XCTAssertEqual(RewardEngine.unlockedPetIDs(values), expected)
            XCTAssertTrue(expected.isSubset(of: catalog))
            XCTAssertEqual(RewardEngine.experience(values), xp)
            XCTAssertTrue(values.filter { $0.key.hasPrefix("pet:") }.allSatisfy { $0.xp == 0 })
        }
    }

    func testStartupReconcileWithoutCandidatesRepairsMissingPetUnlocks() throws {
        let context = try context()
        context.insert(RewardEvent(key: "existing", title: "Existing", xp: 250, earnedAt: date(20)))
        try context.save()
        try RewardEngine.reconcile([], in: context, now: now)
        try RewardEngine.reconcile([], in: context, now: now)
        XCTAssertEqual(try events(context).count, 4)
        XCTAssertEqual(RewardEngine.unlockedPetIDs(try events(context)), Set(["cat", "whale", "bird"]))
    }

    func testCallerRollbackRemovesSourceRewardsReceiptsAndPetUnlocksTogether() throws {
        enum Failure: Error { case simulated }
        let context = try context()
        let goal = savings()
        context.insert(goal)
        try context.save()
        do {
            let deposit = contribution(goal, 1_000)
            context.insert(deposit)
            let record = weight(70)
            context.insert(record)
            let data = AppSnapshot(goals: [goal], contributions: [deposit], weights: [record])
            try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: now)
            XCTAssertFalse(try events(context).isEmpty)
            throw Failure.simulated
        } catch Failure.simulated {
            context.rollback()
        } catch {
            context.rollback()
            throw error
        }
        XCTAssertTrue(try events(context).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SavingsContribution>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WeightRecord>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavingsGoal>()).count, 1)
    }

    func testDeletionLowersProgressButPreservesXPAndPetsThenRestoreCannotReplay() throws {
        let context = try context()
        let goal = savings()
        let deposit = contribution(goal, 1_000)
        context.insert(goal)
        context.insert(deposit)
        var data = AppSnapshot(goals: [goal], contributions: [deposit])
        try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: now)
        try context.save()
        deposit.deletedAt = now
        data.rewards = try events(context)
        let deleted = evaluate(data)
        XCTAssertTrue(deleted.milestones.allSatisfy { !$0.isReached })
        XCTAssertTrue(deleted.candidates.isEmpty)
        try RewardEngine.reconcile(deleted.candidates, in: context, now: now)
        try context.save()
        XCTAssertEqual(RewardEngine.experience(try events(context)), 80)
        XCTAssertEqual(RewardEngine.unlockedPetIDs(try events(context)), Set(["cat"]))
        deposit.deletedAt = nil
        goal.name = "Restored and edited"
        goal.updatedAt = date(22)
        XCTAssertTrue(evaluate(data).candidates.isEmpty)
        try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: date(22))
        try context.save()
        XCTAssertEqual(RewardEngine.experience(try events(context)), 80)
        context.delete(deposit)
        context.delete(goal)
        try RewardEngine.reconcile([], in: context, now: date(22))
        try context.save()
        XCTAssertEqual(RewardEngine.experience(try events(context)), 80)
    }

    func testMovingPreviouslyRewardedWeightToTomorrowCannotFarmXP() throws {
        let context = try context()
        let record = weight(70)
        context.insert(record)
        var data = AppSnapshot(weights: [record])
        try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: now)
        try context.save()
        data.rewards = try events(context)
        record.date = date(22)
        record.updatedAt = date(22)
        let tomorrow = GoalEngine.evaluate(data, now: date(22), calendar: utc)
        XCTAssertTrue(tomorrow.tasks[2].isComplete)
        XCTAssertTrue(tomorrow.candidates.isEmpty)
        try RewardEngine.reconcile(tomorrow.candidates, in: context, now: date(22))
        XCTAssertEqual(RewardEngine.experience(try events(context)), 10)
    }

    func testReconcileAlsoRejectsStaleCandidatesForConsumedSource() throws {
        let context = try context()
        let record = weight(70)
        let data = AppSnapshot(weights: [record])
        let first = evaluate(data)
        record.date = date(22)
        let stale = GoalEngine.evaluate(data, now: date(22), calendar: utc)
        try RewardEngine.reconcile(first.candidates, in: context, now: now)
        try RewardEngine.reconcile(stale.candidates, in: context, now: date(22))
        XCTAssertEqual(RewardEngine.experience(try events(context)), 10)
        XCTAssertEqual(try events(context).count, 2) // Award plus zero-XP recording receipt.
    }

    func testDeletingAndRestoringWeightUUIDRetainsItsLifetimeReceipt() throws {
        let context = try context()
        let record = weight(70)
        let id = record.id
        context.insert(record)
        try RewardEngine.reconcile(evaluate(AppSnapshot(weights: [record])).candidates, in: context, now: now)
        try context.save()
        context.delete(record)
        try RewardEngine.reconcile([], in: context, now: now)
        try context.save()
        let restored = WeightRecord(id: id, kilograms: 70, date: date(22), note: "Restored")
        context.insert(restored)
        let data = AppSnapshot(weights: [restored], rewards: try events(context))
        let result = GoalEngine.evaluate(data, now: date(22), calendar: utc)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(RewardEngine.experience(try events(context)), 10)
    }

    func testInvalidCandidateBatchFailsBeforeAnyRewardInsertion() throws {
        for invalid in [award("bad", xp: -1), award(""), award("source:forged"), award("pet:cat"),
                        RewardCandidate(key: "bad", title: "Bad", xp: 0, petID: "unknown")] {
            let context = try context()
            XCTAssertThrowsError(try RewardEngine.reconcile([award(), invalid], in: context, now: now))
            XCTAssertTrue(try events(context).isEmpty)
        }
    }

    func testOverflowFailsBeforeInsertingAnyPlannedAward() throws {
        let context = try context()
        context.insert(RewardEvent(key: "large", title: "Large", xp: Int.max - 1, earnedAt: now))
        try context.save()
        XCTAssertThrowsError(try RewardEngine.reconcile([award("one", xp: 1), award("two", xp: 1)],
                                                       in: context, now: now))
        XCTAssertEqual(try events(context).map(\.key), ["large"])
    }

    func testExperienceDefensivelyDeduplicatesIgnoresNegativesAndSaturates() {
        let a = RewardEvent(key: "a", title: "A", xp: 10, earnedAt: now)
        let b = RewardEvent(key: "b", title: "B", xp: -10, earnedAt: now)
        let c = RewardEvent(key: "c", title: "C", xp: Int.max, earnedAt: now)
        XCTAssertEqual(RewardEngine.experience([a, a, b]), 10)
        XCTAssertEqual(RewardEngine.experience([a, c]), Int.max)
        XCTAssertEqual(RewardEngine.experience([]), 0)
        let unknown = RewardEvent(key: "unknown", title: "Unknown", xp: 0, petID: "unknown", earnedAt: now)
        XCTAssertTrue(RewardEngine.unlockedPetIDs([unknown]).isEmpty)
    }

    func testPauseResumeAwardsUnseenStagesOnlyOnce() throws {
        let context = try context()
        let goal = savings()
        goal.statusRaw = "paused"
        var data = AppSnapshot(goals: [goal], contributions: [contribution(goal, 1_000)])
        try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: now)
        XCTAssertTrue(try events(context).isEmpty)
        goal.statusRaw = "active"
        try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: now)
        try context.save()
        data.rewards = try events(context)
        goal.statusRaw = "paused"
        XCTAssertTrue(evaluate(data).candidates.isEmpty)
        goal.statusRaw = "active"
        XCTAssertTrue(evaluate(data).candidates.isEmpty)
        XCTAssertEqual(RewardEngine.experience(try events(context)), 80)
    }

    func testZeroOrNegativeNetContributionsDoNotAwardEvenWithLargeSeed() {
        for withdrawal in [Int64(-250), Int64(-500)] {
            let goal = savings(initial: 1_000)
            let data = AppSnapshot(goals: [goal], contributions: [
                contribution(goal, 250), contribution(goal, withdrawal)
            ])
            XCTAssertTrue(evaluate(data).candidates.isEmpty)
        }
    }

    func testFreshRecordOnNextUTCDayCanEarnButSameDayDuplicatesCannot() throws {
        let context = try context()
        let first = weight(70)
        var data = AppSnapshot(weights: [first])
        try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: now)
        data.rewards = try events(context)
        data.weights.append(weight(70))
        XCTAssertTrue(evaluate(data).candidates.isEmpty)
        data.weights.append(weight(70, day: 22))
        let tomorrow = GoalEngine.evaluate(data, now: date(22), calendar: utc)
        XCTAssertEqual(tomorrow.candidates.count, 1)
        try RewardEngine.reconcile(tomorrow.candidates, in: context, now: date(22))
        XCTAssertEqual(RewardEngine.experience(try events(context)), 20)
        XCTAssertEqual(RewardEngine.unlockedPetIDs(try events(context)), Set(["cat"]))
    }

    func testReceiptAlsoPreventsFinanceAndMealDateEditReplay() throws {
        let context = try context()
        let finance = transaction()
        let food = try meal(.manual)
        var data = AppSnapshot(transactions: [finance], meals: [food])
        try RewardEngine.reconcile(evaluate(data).candidates, in: context, now: now)
        try context.save()
        data.rewards = try events(context)
        finance.date = date(22)
        food.recordDate = date(22)
        let tomorrow = GoalEngine.evaluate(data, now: date(22), calendar: utc)
        XCTAssertTrue(tomorrow.tasks[0].isComplete)
        XCTAssertTrue(tomorrow.tasks[1].isComplete)
        XCTAssertTrue(tomorrow.candidates.isEmpty)
        XCTAssertEqual(RewardEngine.experience(try events(context)), 20)
    }
}
