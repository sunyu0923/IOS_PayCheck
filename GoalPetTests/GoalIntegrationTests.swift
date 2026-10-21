// AppViewModel -> LocalRepository -> GoalEngine/RewardEngine integration, iOS 17+.
// Isolated in-memory stores, frozen UTC clocks, no HealthKit/watch/network services.
// Fresh ModelContexts verify committed rows; an Apple SDK host is required to run.
import Foundation
import SwiftData
import XCTest
@testable import GoalPet

@MainActor
private final class GoalIntegrationRepository: AppRepository {
    enum Failure: Error { case afterMutation }

    let local: LocalRepository
    private(set) var commitCount = 0
    // One-shot failure INSIDE LocalRepository.commit, after the app's entire closure
    // (including reconciliation) returns. Only LocalRepository performs rollback.
    var failAfterMutation: ((ModelContext) throws -> Void)?

    init(container: ModelContainer) throws {
        local = try LocalRepository(container: container)
    }

    func load() throws -> AppSnapshot { try local.load() }

    func commit(_ mutation: (ModelContext) throws -> Void) throws -> AppSnapshot {
        commitCount += 1
        let probe = failAfterMutation
        failAfterMutation = nil
        return try local.commit { context in
            try mutation(context)
            if let probe {
                try probe(context)
                throw Failure.afterMutation
            }
        }
    }
}

// Capture values, not SwiftData references, so later mutations cannot change the
// expected ledger and conceal accidental edits to lifetime awards or receipts.
private struct GoalIntegrationAward: Equatable {
    let key: String
    let title: String
    let xp: Int
    let petID: String?
    let earnedAt: Date

    init(_ event: RewardEvent) {
        key = event.key; title = event.title; xp = event.xp
        petID = event.petID; earnedAt = event.earnedAt
    }
}

@MainActor final class GoalIntegrationTests: XCTestCase {
    private func date(_ day: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
    }

    private func repository() throws -> GoalIntegrationRepository {
        try GoalIntegrationRepository(container: LocalRepository.makeContainer(inMemory: true))
    }

    private func model(_ repository: GoalIntegrationRepository, day: Int = 21) throws -> AppViewModel {
        let frozen = date(day)
        return try AppViewModel(repository: repository, now: { frozen },
            foodRecognitionService: MockFoodRecognitionService(delayNanoseconds: 0))
    }

    private func reopen(_ repository: GoalIntegrationRepository, day: Int = 21) throws -> AppViewModel {
        // New repository means a genuinely new writer context, not a reload of the
        // original identity map. Tests stop writing through the old VM after reopening.
        try model(GoalIntegrationRepository(container: repository.local.container), day: day)
    }

    private func freshContext(_ repository: GoalIntegrationRepository) -> ModelContext {
        let context = ModelContext(repository.local.container)
        context.autosaveEnabled = false
        return context
    }

    private func assertCounts(_ repository: GoalIntegrationRepository,
                              transactions: Int = 0, goals: Int = 0, contributions: Int = 0,
                              weights: Int = 0, healthGoals: Int = 0,
                              meals: Int = 0, items: Int = 0, rewards: Int = 0,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let context = freshContext(repository)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserProfile>()), 1, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FinancialAccount>()), 1, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerTransaction>()), transactions, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavingsGoal>()), goals, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavingsContribution>()), contributions, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeightRecord>()), weights, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthGoal>()), healthGoals, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodRecord>()), meals, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodItem>()), items, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RewardEvent>()), rewards, file: file, line: line)
    }

    private func awards(_ events: [RewardEvent]) -> [GoalIntegrationAward] {
        events.map { GoalIntegrationAward($0) }.sorted { $0.key < $1.key }
    }

    @discardableResult
    private func assertLedger(_ app: AppViewModel, _ repository: GoalIntegrationRepository,
                              xp: Int, keys: Set<String>, pets: Set<String> = [],
                              file: StaticString = #filePath, line: UInt = #line) throws -> [GoalIntegrationAward] {
        let context = freshContext(repository)
        let saved = try context.fetch(FetchDescriptor<RewardEvent>())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RewardEvent>()), keys.count, file: file, line: line)
        XCTAssertEqual(saved.count, keys.count, file: file, line: line)
        XCTAssertEqual(Set(saved.map(\.key)), keys, file: file, line: line)
        // Independent arithmetic, not just two calls to the implementation under test.
        XCTAssertEqual(saved.reduce(0) { $0 + $1.xp }, xp, file: file, line: line)
        XCTAssertEqual(Set(saved.compactMap(\.petID)), pets, file: file, line: line)
        XCTAssertEqual(app.experience, xp, file: file, line: line)
        XCTAssertEqual(app.unlockedPetIDs, pets, file: file, line: line)
        XCTAssertEqual(awards(app.data.rewards), awards(saved), file: file, line: line)
        XCTAssertTrue(app.evaluation.candidates.isEmpty, file: file, line: line)
        return awards(saved)
    }

    private func dailyKeys(_ kind: String, id: UUID, day: Int = 21) -> Set<String> {
        ["daily:\(kind):2026-10-\(day)", "source:\(kind):\(id.uuidString.lowercased())"]
    }

    private func savingsKeys(_ id: UUID, stages: [Int] = [25, 50, 75, 100]) -> Set<String> {
        Set(stages.map { "goal:\(id.uuidString.lowercased()):\($0)" })
    }

    private func saveTransaction(_ app: AppViewModel, id: UUID, day: Int = 21,
                                 amount: String = "1", note: String = "Expense") throws {
        try app.saveTransaction(id: id, kind: .expense, amountText: amount,
            category: TransactionKind.expense.categories[0], date: date(day), note: note)
    }

    private func saveWeight(_ app: AppViewModel, id: UUID, day: Int = 21,
                            value: String = "70") throws {
        try app.saveWeight(id: id, value: value, date: date(day), note: "Manual weight")
    }

    private func meal(id: UUID = UUID(), day: Int = 21,
                      source: FoodRecognitionMode = .manual) throws -> ConfirmedFoodMeal {
        var rice = EditableFoodItem(isAIRecognized: source == .remote)
        rice.name = "Rice"; rice.caloriesText = "125"
        var unknown = EditableFoodItem(isAIRecognized: source == .remote)
        unknown.name = "Unknown portion"
        return try ConfirmedFoodMeal.confirm(id: id, mealType: .lunch, date: date(day),
            source: source, drafts: [rice, unknown], userConfirmed: true, now: date(day))
    }

    private func saveGoal(_ app: AppViewModel, title: String = "Personal",
                          initial: String = "0", familyID: UUID? = nil) throws -> SavingsGoal {
        try app.saveGoal(title: title, targetText: "100", initialText: initial,
                         date: date(30), familyID: familyID)
        return try XCTUnwrap(app.data.goals.first { $0.name == title })
    }

    private func deposit(_ app: AppViewModel, goal: SavingsGoal, id: UUID = UUID(),
                         amount: String = "100", withdrawal: Bool = false,
                         memberID: UUID? = nil) throws {
        // Deliberately use the frozen VM clock, never a fixture date before creation.
        XCTAssertGreaterThanOrEqual(app.now(), goal.createdAt)
        try app.saveContribution(id: id, goal: goal, memberID: memberID,
            amountText: amount, withdrawal: withdrawal, date: app.now(), note: "Contribution")
    }

    private func assertStoreFailure(file: StaticString = #filePath, line: UInt = #line,
                                    _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case InputError.invalid(let message) = error else {
                XCTFail("Expected mapped repository error, got \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(message.contains("STORE_WRITE"), file: file, line: line)
        }
    }

    func testEmptyStartupDoesNotCommitOrInventProgress() throws {
        let repository = try repository()
        let app = try model(repository)
        XCTAssertEqual(repository.commitCount, 0)
        XCTAssertEqual(app.evaluation.tasks.count, 3)
        XCTAssertTrue(app.evaluation.tasks.allSatisfy { !$0.isComplete })
        XCTAssertTrue(app.evaluation.milestones.isEmpty)
        try assertLedger(app, repository, xp: 0, keys: [])
        try assertCounts(repository)
    }

    func testDailyAwardsAreIncludedInEachSourceCommitAndUnlockCat() throws {
        let repository = try repository()
        let app = try model(repository)
        let transactionID = UUID(), weightID = UUID()
        let food = try meal()
        try saveTransaction(app, id: transactionID)
        var keys = dailyKeys("finance", id: transactionID)
        try assertLedger(app, repository, xp: 10, keys: keys)
        XCTAssertEqual(repository.commitCount, 1)
        try saveWeight(app, id: weightID)
        keys.formUnion(dailyKeys("weight", id: weightID)); keys.insert("pet:cat")
        try assertLedger(app, repository, xp: 20, keys: keys, pets: ["cat"])
        XCTAssertEqual(repository.commitCount, 2)
        try app.saveConfirmedMeal(food)
        keys.formUnion(dailyKeys("meal", id: food.id))
        let ledger = try assertLedger(app, repository, xp: 30, keys: keys, pets: ["cat"])
        XCTAssertEqual(repository.commitCount, 3) // No nested award-only commit.
        XCTAssertTrue(app.evaluation.tasks.allSatisfy(\.isComplete))
        XCTAssertTrue(ledger.allSatisfy { $0.earnedAt == date(21) })
        try assertCounts(repository, transactions: 1, weights: 1, meals: 1, items: 2, rewards: 7)
    }

    func testRepeatedSavesFreshSameDayRecordsAndRefreshDoNotDuplicateDailyAwards() throws {
        let repository = try repository()
        let app = try model(repository)
        let transactionID = UUID(), weightID = UUID()
        let food = try meal()
        try saveTransaction(app, id: transactionID)
        try saveWeight(app, id: weightID)
        try app.saveConfirmedMeal(food)
        let before = awards(app.data.rewards)
        let keys = Set(before.map(\.key))
        for _ in 0..<3 {
            try saveTransaction(app, id: transactionID)
            try saveWeight(app, id: weightID)
            let commits = repository.commitCount
            try app.saveConfirmedMeal(food)
            XCTAssertEqual(repository.commitCount, commits) // Stable confirmation ID.
            try app.refreshProgress()
        }
        try saveTransaction(app, id: UUID())
        try saveWeight(app, id: UUID())
        try app.saveConfirmedMeal(meal(source: .remote))
        XCTAssertEqual(try assertLedger(app, repository, xp: 30, keys: keys, pets: ["cat"]), before)
        try assertCounts(repository, transactions: 2, weights: 2, meals: 2, items: 4, rewards: 7)
    }

    func testTransactionDeletionAndRestoreChangeTaskButPreserveLifetimeReceipt() throws {
        let repository = try repository()
        let app = try model(repository)
        let id = UUID()
        try saveTransaction(app, id: id)
        let before = awards(app.data.rewards)
        let record = try XCTUnwrap(app.data.transactions.first)
        for deleted in [true, true, false, false] {
            try app.setDeleted(record, deleted: deleted)
            XCTAssertEqual(app.evaluation.tasks.first { $0.id.contains("finance") }?.isComplete, !deleted)
            XCTAssertEqual(try assertLedger(app, repository, xp: 10, keys: dailyKeys("finance", id: id)), before)
            let context = freshContext(repository)
            let saved = try XCTUnwrap(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
            XCTAssertEqual(saved.deletedAt, deleted ? date(21) : nil)
            try assertCounts(repository, transactions: 1, rewards: 2)
        }
    }

    func testTransactionDateEditCannotReplayButFreshNextDayTransactionCanEarn() throws {
        let repository = try repository()
        let app = try model(repository)
        let id = UUID()
        try saveTransaction(app, id: id)
        let before = awards(app.data.rewards)
        let tomorrow = try reopen(repository, day: 22)
        try saveTransaction(tomorrow, id: id, day: 22, amount: "2", note: "Moved")
        XCTAssertEqual(tomorrow.evaluation.tasks.first { $0.id.contains("finance") }?.isComplete, true)
        var keys = dailyKeys("finance", id: id)
        XCTAssertEqual(try assertLedger(tomorrow, repository, xp: 10, keys: keys), before)
        let context = freshContext(repository)
        let edited = try XCTUnwrap(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
        XCTAssertEqual(edited.date, date(22)); XCTAssertEqual(edited.amountMinor, 200)
        let nextID = UUID()
        try saveTransaction(tomorrow, id: nextID, day: 22)
        keys.formUnion(dailyKeys("finance", id: nextID, day: 22)); keys.insert("pet:cat")
        try assertLedger(tomorrow, repository, xp: 20, keys: keys, pets: ["cat"])
        try assertCounts(repository, transactions: 2, rewards: 5)
    }

    func testWeightDateEditAndHardDeleteRestoreCannotReplayConsumedUUID() throws {
        let repository = try repository()
        let app = try model(repository)
        let id = UUID()
        try saveWeight(app, id: id)
        let before = awards(app.data.rewards)
        let tomorrow = try reopen(repository, day: 22)
        try saveWeight(tomorrow, id: id, day: 22, value: "69")
        XCTAssertEqual(try assertLedger(tomorrow, repository, xp: 10, keys: dailyKeys("weight", id: id)), before)
        XCTAssertEqual(tomorrow.evaluation.tasks.first { $0.id.contains("weight") }?.isComplete, true)
        try tomorrow.deleteWeight(XCTUnwrap(tomorrow.data.weights.first))
        XCTAssertEqual(tomorrow.evaluation.tasks.first { $0.id.contains("weight") }?.isComplete, false)
        try assertCounts(repository, rewards: 2)
        try saveWeight(tomorrow, id: id, day: 22)
        XCTAssertEqual(try assertLedger(tomorrow, repository, xp: 10, keys: dailyKeys("weight", id: id)), before)
        let nextID = UUID()
        try saveWeight(tomorrow, id: nextID, day: 22)
        let keys = dailyKeys("weight", id: id).union(dailyKeys("weight", id: nextID, day: 22)).union(["pet:cat"])
        try assertLedger(tomorrow, repository, xp: 20, keys: keys, pets: ["cat"])
        try assertCounts(repository, weights: 2, rewards: 5)
    }

    func testSavingsSeedDoesNotEarnAndStableDepositRetryAwardsOnlyNetNewThreshold() throws {
        let repository = try repository()
        let app = try model(repository)
        let goal = try saveGoal(app, initial: "75")
        XCTAssertEqual(goal.createdAt, date(21))
        XCTAssertEqual(app.evaluation.milestones.filter(\.isReached).map(\.percentage), [25, 50, 75])
        try assertLedger(app, repository, xp: 0, keys: [])
        let id = UUID()
        try deposit(app, goal: goal, id: id, amount: "25")
        let commits = repository.commitCount
        try deposit(app, goal: goal, id: id, amount: "25")
        XCTAssertEqual(repository.commitCount, commits)
        XCTAssertEqual(app.balance(goal), 10_000)
        XCTAssertTrue(app.evaluation.milestones.allSatisfy(\.isReached))
        try assertLedger(app, repository, xp: 20, keys: savingsKeys(goal.id, stages: [25]).union(["pet:cat"]), pets: ["cat"])
        let context = freshContext(repository)
        let saved = try XCTUnwrap(try context.fetch(FetchDescriptor<SavingsContribution>()).first)
        XCTAssertGreaterThanOrEqual(saved.date, goal.createdAt)
        try assertCounts(repository, goals: 1, contributions: 1, rewards: 2)
    }

    func testSavingsDeletionRestoreAndGoalEditNeverRewriteEarnedStages() throws {
        let repository = try repository()
        let app = try model(repository)
        let goal = try saveGoal(app)
        try deposit(app, goal: goal)
        let keys = savingsKeys(goal.id).union(["pet:cat"])
        let before = try assertLedger(app, repository, xp: 80, keys: keys, pets: ["cat"])
        let record = try XCTUnwrap(app.data.contributions.first)
        for deleted in [true, false, false] {
            try app.setDeleted(record, deleted: deleted)
            XCTAssertEqual(app.balance(goal), deleted ? 0 : 10_000)
            XCTAssertTrue(app.evaluation.milestones.allSatisfy { $0.isReached == !deleted })
            XCTAssertEqual(try assertLedger(app, repository, xp: 80, keys: keys, pets: ["cat"]), before)
            let context = freshContext(repository)
            let saved = try XCTUnwrap(try context.fetch(FetchDescriptor<SavingsContribution>()).first)
            XCTAssertEqual(saved.deletedAt, deleted ? date(21) : nil)
        }
        try app.saveGoal(id: goal.id, title: "Renamed", targetText: "50", initialText: "0",
                         date: date(31), familyID: nil)
        XCTAssertEqual(Set(app.evaluation.milestones.map(\.id)), savingsKeys(goal.id))
        XCTAssertEqual(try assertLedger(app, repository, xp: 80, keys: keys, pets: ["cat"]), before)
        let reloaded = try reopen(repository)
        XCTAssertEqual(reloaded.personalGoals.first?.name, "Renamed")
        XCTAssertEqual(reloaded.personalGoals.first?.targetDate, date(31))
        XCTAssertEqual(try assertLedger(reloaded, repository, xp: 80, keys: keys, pets: ["cat"]), before)
        try assertCounts(repository, goals: 1, contributions: 1, rewards: 5)
    }

    func testSavingsWithdrawalAndRedepositCannotReawardReachedStages() throws {
        let repository = try repository()
        let app = try model(repository)
        let goal = try saveGoal(app)
        try deposit(app, goal: goal)
        let before = awards(app.data.rewards)
        try deposit(app, goal: goal, amount: "75", withdrawal: true)
        XCTAssertEqual(app.balance(goal), 2_500)
        XCTAssertEqual(app.evaluation.milestones.filter(\.isReached).map(\.percentage), [25])
        try deposit(app, goal: goal, amount: "75")
        XCTAssertEqual(app.balance(goal), 10_000)
        XCTAssertEqual(try assertLedger(app, repository, xp: 80,
            keys: savingsKeys(goal.id).union(["pet:cat"]), pets: ["cat"]), before)
        try assertCounts(repository, goals: 1, contributions: 3, rewards: 5)
    }

    func testSavingsPauseBlocksWritesAndResumePreservesAwards() throws {
        let repository = try repository()
        let app = try model(repository)
        let goal = try saveGoal(app)
        try deposit(app, goal: goal, amount: "25")
        let before = awards(app.data.rewards)
        try app.archive(goal)
        let commits = repository.commitCount
        XCTAssertThrowsError(try deposit(app, goal: goal, amount: "75"))
        XCTAssertThrowsError(try app.saveGoal(id: goal.id, title: "Blocked", targetText: "100",
            initialText: "0", date: date(30), familyID: nil))
        XCTAssertEqual(repository.commitCount, commits)
        XCTAssertTrue(app.evaluation.milestones.allSatisfy(\.isPaused))
        let resumed = try reopen(repository)
        XCTAssertEqual(resumed.personalGoals.first?.statusRaw, "paused")
        for _ in 0..<2 { try resumed.setGoalPaused(id: goal.id, paused: false) }
        XCTAssertTrue(resumed.evaluation.milestones.allSatisfy { !$0.isPaused })
        XCTAssertEqual(try assertLedger(resumed, repository, xp: 20,
            keys: savingsKeys(goal.id, stages: [25]).union(["pet:cat"]), pets: ["cat"]), before)
        let context = freshContext(repository)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavingsGoal>()).first?.statusRaw, "active")
        try assertCounts(repository, goals: 1, contributions: 1, rewards: 2)
    }

    func testResumeReconcilesPreviouslyUnawardedPausedSavingsExactlyOnce() throws {
        let repository = try repository()
        // Model a previously stored paused plan, not an illegal deposit through the
        // public API while paused. No engine calls or pre-seeded rewards in this setup.
        let goal = SavingsGoal(name: "Imported paused plan", target: 10_000, initial: 0,
            currency: "CNY", targetDate: date(30))
        goal.createdAt = date(20); goal.updatedAt = date(20); goal.statusRaw = "paused"
        let contribution = SavingsContribution(goalID: goal.id, memberID: nil,
            signedMinor: 10_000, date: date(21), note: "Existing deposit")
        _ = try repository.local.commit { $0.insert(goal); $0.insert(contribution) }
        let app = try model(repository)
        XCTAssertEqual(repository.commitCount, 0)
        XCTAssertTrue(app.evaluation.milestones.allSatisfy { $0.isReached && $0.isPaused })
        try assertLedger(app, repository, xp: 0, keys: [])
        try app.setGoalPaused(id: goal.id, paused: false)
        let before = try assertLedger(app, repository, xp: 80,
            keys: savingsKeys(goal.id).union(["pet:cat"]), pets: ["cat"])
        for paused in [true, false, false] { try app.setGoalPaused(id: goal.id, paused: paused) }
        XCTAssertEqual(awards(app.data.rewards), before)
        try assertCounts(repository, goals: 1, contributions: 1, rewards: 5)
    }

    func testResumeEnforcesOneActivePersonalPlanButAllowsActiveFamilyPlan() throws {
        let repository = try repository()
        let app = try model(repository)
        let first = try saveGoal(app, title: "First")
        try app.setGoalPaused(id: first.id, paused: true)
        let second = try saveGoal(app, title: "Second")
        try app.createFamily(title: "Home")
        let familyID = try XCTUnwrap(app.data.families.first?.id)
        _ = try saveGoal(app, title: "Shared", familyID: familyID)
        let commits = repository.commitCount
        XCTAssertThrowsError(try app.setGoalPaused(id: first.id, paused: false)) { error in
            XCTAssertTrue(error is InputError)
        }
        XCTAssertEqual(repository.commitCount, commits)
        XCTAssertEqual(first.statusRaw, "paused"); XCTAssertEqual(second.statusRaw, "active")
        let rejectedContext = freshContext(repository)
        let rejected = try rejectedContext.fetch(FetchDescriptor<SavingsGoal>())
        XCTAssertEqual(rejected.first { $0.id == first.id }?.statusRaw, "paused")
        XCTAssertEqual(rejected.filter { $0.familyGroupID == nil && $0.statusRaw == "active" }.map(\.id), [second.id])
        try app.setGoalPaused(id: second.id, paused: true)
        try app.setGoalPaused(id: first.id, paused: false)
        let reloaded = try reopen(repository)
        XCTAssertEqual(reloaded.personalGoals.filter { $0.statusRaw == "active" }.map(\.id), [first.id])
        XCTAssertEqual(reloaded.data.goals.first { $0.familyGroupID == familyID }?.statusRaw, "active")
        try assertLedger(reloaded, repository, xp: 0, keys: [])
        try assertCounts(repository, goals: 3)
    }

    func testHealthPauseResumeAllowsDailyLoggingButNeverAwardsWeightMilestones() throws {
        let repository = try repository()
        let app = try model(repository, day: 19)
        let birth = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01 UTC; safely adult.
        try app.saveProfile(displayName: "Adult", unit: .kg, heightText: "170", birth: birth,
            sex: .unspecified, activity: .sedentary, estimates: false)
        let firstID = UUID(), secondID = UUID(), thirdID = UUID()
        try saveWeight(app, id: firstID, day: 19, value: "80")
        try app.saveHealthGoal(kind: .lose, targetText: "60")
        let goalID = try XCTUnwrap(app.healthGoal?.id)
        let stageIDs = Set(app.evaluation.milestones.map(\.id))
        XCTAssertEqual(stageIDs, savingsKeys(goalID))
        try app.setHealthGoalPaused(true)
        let commits = repository.commitCount
        XCTAssertThrowsError(try app.saveHealthGoal(kind: .lose, targetText: "65"))
        XCTAssertEqual(repository.commitCount, commits)
        let secondDay = try reopen(repository, day: 20)
        XCTAssertEqual(secondDay.healthGoal?.statusRaw, "paused")
        try saveWeight(secondDay, id: secondID, day: 20, value: "60")
        let thirdDay = try reopen(repository)
        try saveWeight(thirdDay, id: thirdID, value: "60")
        XCTAssertTrue(thirdDay.evaluation.milestones.allSatisfy(\.isPaused))
        XCTAssertEqual(thirdDay.evaluation.milestones.filter(\.isReached).map(\.percentage), [25, 50])
        let keys = dailyKeys("weight", id: firstID, day: 19)
            .union(dailyKeys("weight", id: secondID, day: 20))
            .union(dailyKeys("weight", id: thirdID)).union(["pet:cat"])
        let before = try assertLedger(thirdDay, repository, xp: 30, keys: keys, pets: ["cat"])
        for paused in [false, true, false, false] { try thirdDay.setHealthGoalPaused(paused) }
        XCTAssertTrue(thirdDay.evaluation.milestones.allSatisfy { !$0.isPaused })
        try thirdDay.saveHealthGoal(kind: .lose, targetText: "55")
        XCTAssertEqual(Set(thirdDay.evaluation.milestones.map(\.id)), stageIDs)
        XCTAssertEqual(try assertLedger(thirdDay, repository, xp: 30, keys: keys, pets: ["cat"]), before)
        let context = freshContext(repository)
        let saved = try XCTUnwrap(try context.fetch(FetchDescriptor<HealthGoal>()).first)
        XCTAssertEqual(saved.id, goalID); XCTAssertEqual(saved.statusRaw, "active")
        XCTAssertEqual(saved.targetKG, 55); XCTAssertEqual(saved.startDate, date(21))
        try assertCounts(repository, weights: 3, healthGoals: 1, rewards: 7)
    }

    func testFamilySavingsCompletionPauseResumeAndRestoreNeverGrantPersonalXP() throws {
        let repository = try repository()
        let app = try model(repository)
        try app.createFamily(title: "Home")
        let family = try XCTUnwrap(app.data.families.first)
        let member = try XCTUnwrap(app.members(in: family.id).first)
        let goal = try saveGoal(app, title: "Family", familyID: family.id)
        try deposit(app, goal: goal, memberID: member.id)
        XCTAssertEqual(app.balance(goal), 10_000)
        XCTAssertTrue(app.evaluation.milestones.allSatisfy(\.isReached))
        try assertLedger(app, repository, xp: 0, keys: [])
        try app.setGoalPaused(id: goal.id, paused: true)
        XCTAssertTrue(app.evaluation.milestones.allSatisfy(\.isPaused))
        try app.setGoalPaused(id: goal.id, paused: false)
        let contribution = try XCTUnwrap(app.data.contributions.first)
        try app.setDeleted(contribution, deleted: true)
        XCTAssertTrue(app.evaluation.milestones.allSatisfy { !$0.isReached })
        try app.setDeleted(contribution, deleted: false)
        let reloaded = try reopen(repository)
        XCTAssertTrue(reloaded.evaluation.milestones.allSatisfy { $0.isReached && !$0.isPaused })
        try assertLedger(reloaded, repository, xp: 0, keys: [])
        try assertCounts(repository, goals: 1, contributions: 1)
    }

    func testFailedTransactionInsertionRollsBackSourceAwardReceiptAndPetTogether() throws {
        let repository = try repository()
        let app = try model(repository)
        let weightID = UUID(), transactionID = UUID()
        try saveWeight(app, id: weightID)
        let before = awards(app.data.rewards)
        var observed = false
        repository.failAfterMutation = { context in
            observed = true
            XCTAssertFalse(context.autosaveEnabled)
            let pending = try context.fetch(FetchDescriptor<LedgerTransaction>())
            XCTAssertEqual(pending.map(\.id), [transactionID])
            let rewards = try context.fetch(FetchDescriptor<RewardEvent>())
            XCTAssertEqual(rewards.count, 5)
            XCTAssertEqual(rewards.reduce(0) { $0 + $1.xp }, 20)
            XCTAssertEqual(Set(rewards.compactMap(\.petID)), ["cat"])
        }
        let commits = repository.commitCount
        assertStoreFailure { try saveTransaction(app, id: transactionID) }
        XCTAssertTrue(observed, "Failure must occur after the app reconciles pending rewards")
        XCTAssertEqual(repository.commitCount, commits + 1)
        XCTAssertTrue(app.data.transactions.isEmpty)
        XCTAssertTrue(try repository.load().transactions.isEmpty)
        XCTAssertEqual(try assertLedger(app, repository, xp: 10, keys: dailyKeys("weight", id: weightID)), before)
        try assertCounts(repository, weights: 1, rewards: 2)
        try saveTransaction(app, id: transactionID)
        let keys = dailyKeys("weight", id: weightID).union(dailyKeys("finance", id: transactionID)).union(["pet:cat"])
        try assertLedger(app, repository, xp: 20, keys: keys, pets: ["cat"])
        try assertCounts(repository, transactions: 1, weights: 1, rewards: 5)
    }

    func testFailedTransactionEditRestoresCachedAndPersistedFieldsAndRewards() throws {
        let repository = try repository()
        let app = try model(repository)
        let id = UUID()
        try saveTransaction(app, id: id, day: 20, note: "Original")
        let record = try XCTUnwrap(app.data.transactions.first)
        let updatedAt = record.updatedAt
        var observed = false
        repository.failAfterMutation = { context in
            observed = true
            let pending = try XCTUnwrap(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
            XCTAssertEqual(pending.id, id); XCTAssertEqual(pending.amountMinor, 900)
            XCTAssertEqual(pending.date, self.date(21)); XCTAssertEqual(pending.note, "Edited")
            XCTAssertEqual(try context.fetch(FetchDescriptor<RewardEvent>()).count, 2)
        }
        assertStoreFailure { try saveTransaction(app, id: id, amount: "9", note: "Edited") }
        XCTAssertTrue(observed)
        // AppSnapshot holds reference models: rollback must repair these too.
        XCTAssertEqual(record.amountMinor, 100); XCTAssertEqual(record.date, date(20))
        XCTAssertEqual(record.note, "Original"); XCTAssertEqual(record.updatedAt, updatedAt)
        let cached = try XCTUnwrap(app.data.transactions.first)
        XCTAssertEqual(cached.amountMinor, 100); XCTAssertEqual(cached.date, date(20))
        let context = freshContext(repository)
        let saved = try XCTUnwrap(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
        XCTAssertEqual(saved.amountMinor, 100); XCTAssertEqual(saved.date, date(20))
        XCTAssertEqual(saved.note, "Original"); XCTAssertEqual(saved.updatedAt, updatedAt)
        try assertLedger(app, repository, xp: 0, keys: [])
        try assertCounts(repository, transactions: 1)
        try saveTransaction(app, id: id, amount: "9", note: "Edited")
        try assertLedger(app, repository, xp: 10, keys: dailyKeys("finance", id: id))
        try assertCounts(repository, transactions: 1, rewards: 2)
    }

    func testFailedSavingsDepositRollsBackAllFourMilestonesAndCanRetrySameID() throws {
        let repository = try repository()
        let app = try model(repository)
        let goal = try saveGoal(app)
        let id = UUID()
        var observed = false
        repository.failAfterMutation = { context in
            observed = true
            let pending = try context.fetch(FetchDescriptor<SavingsContribution>())
            XCTAssertEqual(pending.map(\.id), [id])
            let rewards = try context.fetch(FetchDescriptor<RewardEvent>())
            XCTAssertEqual(Set(rewards.map(\.key)), self.savingsKeys(goal.id).union(["pet:cat"]))
            XCTAssertEqual(rewards.reduce(0) { $0 + $1.xp }, 80)
        }
        assertStoreFailure { try deposit(app, goal: goal, id: id) }
        XCTAssertTrue(observed)
        XCTAssertTrue(app.data.contributions.isEmpty)
        XCTAssertEqual(app.balance(goal), 0)
        XCTAssertTrue(app.evaluation.milestones.allSatisfy { !$0.isReached })
        try assertLedger(app, repository, xp: 0, keys: [])
        try assertCounts(repository, goals: 1)
        try deposit(app, goal: goal, id: id)
        try deposit(app, goal: goal, id: id)
        try assertLedger(app, repository, xp: 80, keys: savingsKeys(goal.id).union(["pet:cat"]), pets: ["cat"])
        try assertCounts(repository, goals: 1, contributions: 1, rewards: 5)
    }

    func testFailedMealSaveRollsBackOwnedItemsDailyRewardAndUnlockThenRetries() throws {
        let repository = try repository()
        let app = try model(repository)
        let weightID = UUID()
        try saveWeight(app, id: weightID)
        let food = try meal(source: .remote)
        let before = awards(app.data.rewards)
        var observed = false
        repository.failAfterMutation = { context in
            observed = true
            XCTAssertEqual(try context.fetch(FetchDescriptor<FoodRecord>()).map(\.id), [food.id])
            let items = try context.fetch(FetchDescriptor<FoodItem>())
            XCTAssertEqual(items.count, 2)
            XCTAssertTrue(items.allSatisfy { $0.record?.id == food.id })
            let rewards = try context.fetch(FetchDescriptor<RewardEvent>())
            XCTAssertEqual(rewards.count, 5)
            XCTAssertTrue(rewards.contains { $0.key == "pet:cat" })
        }
        assertStoreFailure { try app.saveConfirmedMeal(food) }
        XCTAssertTrue(observed)
        XCTAssertTrue(app.data.meals.isEmpty)
        XCTAssertEqual(try assertLedger(app, repository, xp: 10, keys: dailyKeys("weight", id: weightID)), before)
        try assertCounts(repository, weights: 1, rewards: 2)
        try app.saveConfirmedMeal(food)
        let commits = repository.commitCount
        try app.saveConfirmedMeal(food)
        XCTAssertEqual(repository.commitCount, commits)
        let keys = dailyKeys("weight", id: weightID).union(dailyKeys("meal", id: food.id)).union(["pet:cat"])
        try assertLedger(app, repository, xp: 20, keys: keys, pets: ["cat"])
        try assertCounts(repository, weights: 1, meals: 1, items: 2, rewards: 5)
    }

    func testStartupReconcilesStoredSourcesAndFreshVMsPreserveExactLedger() throws {
        let repository = try repository()
        let account = try XCTUnwrap(try repository.load().accounts.first)
        let transaction = LedgerTransaction(kind: .expense, amount: 100, currency: "CNY",
            category: TransactionKind.expense.categories[0], accountID: account.id, date: date(21), note: "Existing")
        let weight = WeightRecord(kilograms: 70, date: date(21), note: "Existing")
        let food = try meal()
        let goal = SavingsGoal(name: "Existing", target: 10_000, initial: 0, currency: "CNY", targetDate: date(30))
        goal.createdAt = date(20); goal.updatedAt = date(20)
        _ = try repository.local.commit { context in
            context.insert(transaction); context.insert(weight); context.insert(goal)
            context.insert(SavingsContribution(goalID: goal.id, memberID: nil, signedMinor: 10_000,
                date: self.date(21), note: "Post-creation deposit"))
            let record = FoodRecord(meal: food, confirmedAt: self.date(21))
            context.insert(record)
            for value in food.foods {
                let item = FoodItem(value: value); context.insert(item); item.record = record
            }
        }
        try assertCounts(repository, transactions: 1, goals: 1, contributions: 1, weights: 1, meals: 1, items: 2)
        let app = try model(repository)
        XCTAssertEqual(repository.commitCount, 1)
        let keys = dailyKeys("finance", id: transaction.id).union(dailyKeys("weight", id: weight.id))
            .union(dailyKeys("meal", id: food.id)).union(savingsKeys(goal.id)).union(["pet:cat", "pet:whale"])
        let before = try assertLedger(app, repository, xp: 110, keys: keys, pets: ["cat", "whale"])
        XCTAssertTrue(before.allSatisfy { $0.earnedAt == date(21) })
        for day in [21, 21, 22] {
            let reloaded = try reopen(repository, day: day)
            try reloaded.refreshProgress()
            XCTAssertEqual(try assertLedger(reloaded, repository, xp: 110, keys: keys, pets: ["cat", "whale"]), before)
            if day == 22 { XCTAssertTrue(reloaded.evaluation.tasks.allSatisfy { !$0.isComplete }) }
            try assertCounts(repository, transactions: 1, goals: 1, contributions: 1,
                             weights: 1, meals: 1, items: 2, rewards: 12)
        }
    }

    func testStartupRepairsMissingPetRowsWithoutChangingExistingAward() throws {
        let repository = try repository()
        _ = try repository.local.commit { context in
            context.insert(RewardEvent(key: "legacy:award", title: "Original title", xp: 250, earnedAt: self.date(20)))
        }
        let app = try model(repository)
        let keys: Set<String> = ["legacy:award", "pet:cat", "pet:whale", "pet:bird"]
        let before = try assertLedger(app, repository, xp: 250, keys: keys, pets: ["cat", "whale", "bird"])
        let legacy = try XCTUnwrap(before.first { $0.key == "legacy:award" })
        XCTAssertEqual(legacy.title, "Original title"); XCTAssertEqual(legacy.earnedAt, date(20))
        XCTAssertTrue(before.filter { $0.key.hasPrefix("pet:") }.allSatisfy { $0.xp == 0 && $0.earnedAt == date(21) })
        let reloaded = try reopen(repository, day: 22)
        XCTAssertEqual(try assertLedger(reloaded, repository, xp: 250, keys: keys, pets: ["cat", "whale", "bird"]), before)
        try assertCounts(repository, rewards: 4)
    }

    func testStartupFailureRollsBackReconciliationAndNextStartupCanRetry() throws {
        let repository = try repository()
        let account = try XCTUnwrap(try repository.load().accounts.first)
        let transaction = LedgerTransaction(kind: .expense, amount: 100, currency: "CNY",
            category: TransactionKind.expense.categories[0], accountID: account.id, date: date(21), note: "Existing")
        let weight = WeightRecord(kilograms: 70, date: date(21), note: "Existing")
        _ = try repository.local.commit { $0.insert(transaction); $0.insert(weight) }
        var observed = false
        repository.failAfterMutation = { context in
            observed = true
            let rewards = try context.fetch(FetchDescriptor<RewardEvent>())
            XCTAssertEqual(rewards.count, 5)
            XCTAssertEqual(rewards.reduce(0) { $0 + $1.xp }, 20)
        }
        assertStoreFailure { _ = try model(repository) }
        XCTAssertTrue(observed)
        XCTAssertTrue(try repository.load().rewards.isEmpty)
        try assertCounts(repository, transactions: 1, weights: 1)
        let app = try reopen(repository)
        let keys = dailyKeys("finance", id: transaction.id).union(dailyKeys("weight", id: weight.id)).union(["pet:cat"])
        try assertLedger(app, repository, xp: 20, keys: keys, pets: ["cat"])
        try assertCounts(repository, transactions: 1, weights: 1, rewards: 5)
    }

    func testManualAndRemoteMealCompatibilityIncludesCascadeAndSameUUIDRestore() throws {
        // Remote means a confirmed source label here; no recognition/upload is invoked.
        for source in [FoodRecognitionMode.manual, .remote] {
            let repository = try repository()
            let app = try model(repository)
            let food = try meal(source: source)
            XCTAssertEqual(repository.commitCount, 0) // Confirmation alone is not a write.
            try assertCounts(repository)
            try app.saveConfirmedMeal(food)
            try app.saveConfirmedMeal(food)
            XCTAssertEqual(repository.commitCount, 1)
            let keys = dailyKeys("meal", id: food.id)
            let before = try assertLedger(app, repository, xp: 10, keys: keys)
            let context = freshContext(repository)
            let saved = try XCTUnwrap(try context.fetch(FetchDescriptor<FoodRecord>()).first)
            XCTAssertEqual(saved.sourceRaw, source.rawValue); XCTAssertEqual(saved.confirmedAt, date(21))
            XCTAssertEqual(saved.knownCalories, 125); XCTAssertTrue(saved.hasIncompleteCalories)
            XCTAssertEqual(Set(saved.items.map(\.id)), Set(food.foods.map(\.id)))
            XCTAssertTrue(saved.items.allSatisfy { $0.record?.id == food.id })
            XCTAssertTrue(saved.items.allSatisfy { $0.isAIRecognized == (source == .remote) })
            let unknown = try XCTUnwrap(saved.items.first { $0.name == "Unknown portion" })
            XCTAssertNil(unknown.calories); XCTAssertNil(unknown.weightGrams); XCTAssertNil(unknown.proteinGrams)
            try assertCounts(repository, meals: 1, items: 2, rewards: 2)
            try app.deleteMeal(XCTUnwrap(app.data.meals.first))
            XCTAssertEqual(app.evaluation.tasks.first { $0.id.contains("meal") }?.isComplete, false)
            XCTAssertEqual(try assertLedger(app, repository, xp: 10, keys: keys), before)
            try assertCounts(repository, rewards: 2) // Cascade removes both owned items.
            let tomorrow = try reopen(repository, day: 22)
            let restored = try meal(id: food.id, day: 22, source: source)
            try tomorrow.saveConfirmedMeal(restored)
            XCTAssertEqual(tomorrow.evaluation.tasks.first { $0.id.contains("meal") }?.isComplete, true)
            XCTAssertEqual(try assertLedger(tomorrow, repository, xp: 10, keys: keys), before)
            try assertCounts(repository, meals: 1, items: 2, rewards: 2)
        }
    }

    func testMockAndFutureMealsAreRejectedWithoutCommitsAndPastMealsAreNotBackfilled() throws {
        let repository = try repository()
        let app = try model(repository)
        let mock = try meal(source: .mock)
        XCTAssertThrowsError(try app.saveConfirmedMeal(mock)) { error in
            XCTAssertEqual(error as? FoodRecognitionError, .demoCannotPersist)
        }
        let future = try meal(day: 22)
        XCTAssertThrowsError(try app.saveConfirmedMeal(future)) { error in XCTAssertTrue(error is InputError) }
        XCTAssertEqual(repository.commitCount, 0)
        try assertCounts(repository)
        try app.saveConfirmedMeal(meal(day: 20))
        XCTAssertEqual(repository.commitCount, 1)
        try assertLedger(app, repository, xp: 0, keys: [])
        let reloaded = try reopen(repository)
        XCTAssertTrue(reloaded.evaluation.tasks.allSatisfy { !$0.isComplete })
        try assertLedger(reloaded, repository, xp: 0, keys: [])
        try assertCounts(repository, meals: 1, items: 2)
    }
}
