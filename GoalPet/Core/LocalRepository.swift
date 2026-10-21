// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Core/LocalRepository.swift
// Purpose: Local-only SwiftData container and rollback-safe persistence boundary. Dependencies: Models.
import Foundation
import SwiftData

struct AppSnapshot {
    var profiles: [UserProfile] = []
    var accounts: [FinancialAccount] = []
    var transactions: [LedgerTransaction] = []
    var budgets: [Budget] = []
    var goals: [SavingsGoal] = []
    var contributions: [SavingsContribution] = []
    var weights: [WeightRecord] = []
    var healthGoals: [HealthGoal] = []
    var families: [FamilyGroup] = []
    var members: [FamilyMember] = []
    var meals: [FoodRecord] = []
    var rewards: [RewardEvent] = []
}

@MainActor protocol AppRepository {
    func load() throws -> AppSnapshot
    func commit(_ mutation: (ModelContext) throws -> Void) throws -> AppSnapshot
}

@MainActor final class LocalRepository: AppRepository {
    let container: ModelContainer
    private let context: ModelContext

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            UserProfile.self, FinancialAccount.self, LedgerTransaction.self, Budget.self,
            SavingsGoal.self, SavingsContribution.self, WeightRecord.self, HealthGoal.self,
            FamilyGroup.self, FamilyMember.self, FoodRecord.self, FoodItem.self, RewardEvent.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory,
                                               cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    init(container: ModelContainer) throws {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
        // Only operational defaults: never seed real accounts with fake money/health data.
        if try context.fetch(FetchDescriptor<UserProfile>()).isEmpty {
            context.insert(UserProfile())
        }
        if try context.fetch(FetchDescriptor<FinancialAccount>()).isEmpty {
            context.insert(FinancialAccount(currency: "CNY"))
        }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func load() throws -> AppSnapshot {
        AppSnapshot(
            profiles: try context.fetch(FetchDescriptor<UserProfile>()),
            accounts: try context.fetch(FetchDescriptor<FinancialAccount>()),
            transactions: try context.fetch(FetchDescriptor<LedgerTransaction>(sortBy: [SortDescriptor(\.date, order: .reverse)])),
            budgets: try context.fetch(FetchDescriptor<Budget>()),
            goals: try context.fetch(FetchDescriptor<SavingsGoal>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])),
            contributions: try context.fetch(FetchDescriptor<SavingsContribution>(sortBy: [SortDescriptor(\.date, order: .reverse)])),
            weights: try context.fetch(FetchDescriptor<WeightRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])),
            healthGoals: try context.fetch(FetchDescriptor<HealthGoal>()),
            families: try context.fetch(FetchDescriptor<FamilyGroup>()),
            members: try context.fetch(FetchDescriptor<FamilyMember>()),
            meals: try context.fetch(FetchDescriptor<FoodRecord>(sortBy: [SortDescriptor(\.recordDate, order: .reverse)])),
            rewards: try context.fetch(FetchDescriptor<RewardEvent>(sortBy: [SortDescriptor(\.earnedAt, order: .reverse)]))
        )
    }

    func commit(_ mutation: (ModelContext) throws -> Void) throws -> AppSnapshot {
        do {
            try mutation(context)
            // Fetch before save: a read failure must not report a committed write as failed.
            let snapshot = try load()
            try context.save()
            return snapshot
        } catch {
            context.rollback()
            throw error
        }
    }
}