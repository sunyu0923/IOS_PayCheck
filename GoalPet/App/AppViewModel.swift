// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/App/AppViewModel.swift
// Purpose: Shared observable view model; all UI writes are validated here. Dependencies: AppRepository, Models, Calculations.
import Foundation
import Observation
import SwiftData

@MainActor @Observable final class AppViewModel {
    private(set) var data: AppSnapshot
    @ObservationIgnored private let repository: any AppRepository
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let foodRecognitionService: any FoodRecognitionService

    init(repository: any AppRepository, now: @escaping () -> Date = { .now },
         foodRecognitionService: any FoodRecognitionService = MockFoodRecognitionService()) throws {
        self.repository = repository; self.now = now; self.foodRecognitionService = foodRecognitionService
        data = try repository.load()
        if !evaluation.candidates.isEmpty || !data.rewards.isEmpty {
            try refreshProgress()
        }
    }

    var evaluation: GoalEvaluation { GoalEngine.evaluate(data, now: now()) }
    var experience: Int { RewardEngine.experience(data.rewards) }
    var unlockedPetIDs: Set<String> { RewardEngine.unlockedPetIDs(data.rewards) }

    func refreshProgress() throws { try write { _ in } }

    var profile: UserProfile? { data.profiles.first }
    var currency: String { profile?.currency ?? "CNY" }
    var unit: WeightUnit { WeightUnit(rawValue: profile?.weightUnitRaw ?? "") ?? .kg }
    var budget: Budget? { data.budgets.first { $0.currency == currency } }
    var healthGoal: HealthGoal? { data.healthGoals.first }
    var latestWeight: WeightRecord? { data.weights.first }
    var activeTransactions: [LedgerTransaction] { data.transactions.filter { $0.deletedAt == nil } }
    var personalGoals: [SavingsGoal] { data.goals.filter { $0.familyGroupID == nil } }
    var period: DateInterval? { BudgetCalendar.interval(containing: now(), startDay: budget?.startDay ?? 1) }
    var age: Int? {
        guard let birth = profile?.dateOfBirth else { return nil }
        return Calendar.current.dateComponents([.year], from: birth, to: now()).year
    }
    var weightPoints: [WeightPoint] { data.weights.map { WeightPoint(date: $0.date, kg: $0.kilograms) } }
    var bmr: ClosedRange<Double>? {
        guard profile?.estimatesEnabled == true, let kg = latestWeight?.kilograms,
              let height = profile?.heightCM, let age else { return nil }
        return HealthMath.bmr(kg: kg, heightCM: height, age: age,
                              sex: BiologicalSex(rawValue: profile?.sexRaw ?? "") ?? .unspecified)
    }
    var tdee: ClosedRange<Double>? {
        guard let bmr else { return nil }
        return HealthMath.tdee(bmr: bmr, activity: ActivityLevel(rawValue: profile?.activityRaw ?? "") ?? .sedentary)
    }

    func total(_ kind: TransactionKind) -> Int64 {
        guard let period else { return 0 }
        return activeTransactions.filter {
            $0.kindRaw == kind.rawValue && $0.currency == currency && $0.date >= period.start && $0.date < period.end
        }.reduce(0) { $0 + $1.amountMinor }
    }
    func contributions(for goal: SavingsGoal, includeDeleted: Bool = false) -> [SavingsContribution] {
        data.contributions.filter { $0.goalID == goal.id && (includeDeleted || $0.deletedAt == nil) }
    }
    func balance(_ goal: SavingsGoal) -> Int64 {
        contributions(for: goal).reduce(goal.initialMinor) { $0 + $1.signedMinor }
    }
    func members(in familyID: UUID) -> [FamilyMember] {
        data.members.filter { $0.groupID == familyID && !$0.isArchived }
    }
    func memberName(_ id: UUID?) -> String {
        guard let id else { return L10n.text("个人") }
        return data.members.first { $0.id == id }?.displayName ?? L10n.text("已归档成员")
    }

    func write(_ mutation: (ModelContext) throws -> Void) throws {
        do {
            data = try repository.commit { context in
                try mutation(context)
                // Same context, pending source changes and awards, ONE save/rollback.
                let pending = try repository.load()
                let result = GoalEngine.evaluate(pending, now: now())
                try RewardEngine.reconcile(result.candidates, in: context, now: now())
            }
        }
        catch let error as InputError { throw error }
        catch { throw InputError.invalid("暂时无法保存，请保留输入并重试。错误码：STORE_WRITE") }
    }
    private func validDate(_ date: Date) throws {
        guard date <= now() else { throw InputError.invalid("记录时间不能晚于现在") }
    }
    func name(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 60 else { throw InputError.invalid("名称需要包含 1 至 60 个字符") }
        return text
    }

    func saveTransaction(id: UUID, kind: TransactionKind, amountText: String, category: String, date: Date, note: String) throws {
        let existing = data.transactions.first { $0.id == id }
        let code = existing?.currency ?? currency
        let amount = try Money.parse(amountText, currency: code)
        try validDate(date)
        guard kind.categories.contains(category), let account = data.accounts.first(where: { account in
            if let existing { return account.id == existing.accountID && account.currency == code }
            return account.currency == code && !account.isArchived
        }) else {
            throw InputError.invalid("请选择有效分类和账户")
        }
        // Bound the entire ledger, including deleted records, so all Int64 reductions remain safe.
        let otherTotal = data.transactions.filter { $0.id != id }.reduce(Int64(0)) { $0 + $1.amountMinor }
        guard try Money.add(otherTotal, amount) <= Money.maximum else { throw InputError.invalid("账本金额合计超出本版本范围") }
        try write { context in
            if let record = data.transactions.first(where: { $0.id == id }) {
                guard record.deletedAt == nil else { throw InputError.invalid("请先恢复已删除账单") }
                record.kindRaw = kind.rawValue; record.amountMinor = amount; record.category = category
                record.date = date; record.note = note; record.updatedAt = now()
            } else {
                context.insert(LedgerTransaction(id: id, kind: kind, amount: amount, currency: code,
                                                 category: category, accountID: account.id, date: date, note: note))
            }
        }
    }

    func setDeleted(_ record: LedgerTransaction, deleted: Bool) throws {
        try write { _ in record.deletedAt = deleted ? now() : nil; record.updatedAt = now() }
    }

    func setBudget(amountText: String, startDay: Int) throws {
        let amount = try Money.parse(amountText, currency: currency)
        guard (1...28).contains(startDay) else { throw InputError.invalid("起始日需为 1 至 28 日") }
        try write { context in
            if let budget { budget.amountMinor = amount; budget.startDay = startDay }
            else { context.insert(Budget(amount: amount, currency: currency, startDay: startDay)) }
        }
    }

    func saveGoal(id: UUID? = nil, title: String, targetText: String, initialText: String,
                  date: Date, familyID: UUID?) throws {
        let title = try name(title)
        let existing = data.goals.first { $0.id == id }
        if id != nil && existing == nil { throw InputError.invalid("目标不存在") }
        if let existing, existing.statusRaw != "active" { throw InputError.invalid("请先恢复目标再编辑") }
        if let existing, existing.familyGroupID != familyID { throw InputError.invalid("不能更改目标所属范围") }
        let code = existing?.currency ?? currency
        let target = try Money.parse(targetText, currency: code)
        let initial = try Money.parse(initialText, currency: code, allowZero: true)
        guard initial <= target else { throw InputError.invalid("初始金额不能超过目标金额") }
        guard Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: now()) else {
            throw InputError.invalid("请选择今天或之后的目标日期")
        }
        if let familyID {
            guard data.families.contains(where: { $0.id == familyID }) else { throw InputError.invalid("家庭组不存在") }
        } else if data.goals.contains(where: { $0.familyGroupID == nil && $0.statusRaw == "active" && $0.id != id }) {
            throw InputError.invalid("本阶段支持一个活跃个人计划，请先归档原计划")
        }
        if let existing {
            let changes = contributions(for: existing).reduce(Int64(0)) { $0 + $1.signedMinor }
            let result = try Money.add(initial, changes)
            guard result >= 0, result <= Money.maximum else { throw InputError.invalid("修改后计划余额超出范围") }
        }
        try write { context in
            if let existing {
                existing.name = title; existing.targetMinor = target; existing.initialMinor = initial
                existing.targetDate = date; existing.updatedAt = now()
            } else {
                let goal = SavingsGoal(name: title, target: target, initial: initial, currency: code,
                                       targetDate: date, familyGroupID: familyID)
                goal.createdAt = now(); goal.updatedAt = now()
                context.insert(goal)
            }
        }
    }

    func archive(_ goal: SavingsGoal) throws {
        try setGoalPaused(id: goal.id, paused: true)
    }

    func setGoalPaused(id: UUID, paused: Bool) throws {
        guard let goal = data.goals.first(where: { $0.id == id }) else { throw InputError.invalid("目标不存在") }
        if !paused, goal.familyGroupID == nil,
           data.goals.contains(where: { $0.id != id && $0.familyGroupID == nil && $0.statusRaw == "active" }) {
            throw InputError.invalid("请先暂停其他进行中的个人目标")
        }
        try write { _ in goal.statusRaw = paused ? "paused" : "active"; goal.updatedAt = now() }
    }

    func setHealthGoalPaused(_ paused: Bool) throws {
        guard let goal = healthGoal else { throw InputError.invalid("尚无健康目标") }
        try write { _ in goal.statusRaw = paused ? "paused" : "active"; goal.updatedAt = now() }
    }

    func saveContribution(id: UUID, goal: SavingsGoal, memberID: UUID?, amountText: String,
                          withdrawal: Bool, date: Date, note: String) throws {
        // An operation ID is generated once per form; retries cannot duplicate a deposit.
        if data.contributions.contains(where: { $0.id == id }) { return }
        guard goal.statusRaw == "active" else { throw InputError.invalid("归档目标不能新增资金记录") }
        try validDate(date)
        let amount = try Money.parse(amountText, currency: goal.currency)
        if let family = goal.familyGroupID {
            guard members(in: family).contains(where: { $0.id == memberID }) else { throw InputError.invalid("请选择该家庭的成员") }
        } else if memberID != nil { throw InputError.invalid("个人目标不能指定家庭成员") }
        let signed = withdrawal ? -amount : amount
        let result = try Money.add(balance(goal), signed)
        let absoluteTotal = contributions(for: goal, includeDeleted: true).reduce(Int64(0)) { $0 + abs($1.signedMinor) }
        guard result >= 0, result <= Money.maximum,
              try Money.add(absoluteTotal, amount) <= Money.maximum else {
            throw InputError.invalid("取出不能超过余额，且资金记录合计不能超出本版本范围")
        }
        try write { context in
            context.insert(SavingsContribution(id: id, goalID: goal.id, memberID: memberID,
                                               signedMinor: signed, date: date, note: note))
        }
    }

    func setDeleted(_ contribution: SavingsContribution, deleted: Bool) throws {
        guard let goal = data.goals.first(where: { $0.id == contribution.goalID }) else { throw InputError.invalid("目标不存在") }
        if deleted == (contribution.deletedAt != nil) { return }
        let result = try Money.add(balance(goal), deleted ? -contribution.signedMinor : contribution.signedMinor)
        guard result >= 0, result <= Money.maximum else { throw InputError.invalid("此操作会使目标余额超出范围，请先处理相关取出记录") }
        try write { _ in contribution.deletedAt = deleted ? now() : nil }
    }

    func saveWeight(id: UUID, value: String, date: Date, note: String, preserveMeasurement: Bool = false) throws {
        let existing = data.weights.first { $0.id == id }
        let kg: Double
        if preserveMeasurement, let existing { kg = existing.kilograms }
        else { kg = unit.kilograms(try NumberInput.parse(value)) }
        guard (10...500).contains(kg) else { throw InputError.invalid("请检查体重数值与单位") }
        try validDate(date)
        try write { context in
            if let record = data.weights.first(where: { $0.id == id }) {
                record.kilograms = kg; record.date = date; record.note = note; record.updatedAt = now()
            } else { context.insert(WeightRecord(id: id, kilograms: kg, date: date, note: note)) }
        }
    }
    func deleteWeight(_ record: WeightRecord) throws { try write { $0.delete(record) } }

    func saveHealthGoal(kind: HealthGoalKind, targetText: String) throws {
        guard healthGoal?.statusRaw != "paused" else { throw InputError.invalid("请先恢复健康目标再编辑") }
        guard let current = latestWeight?.kilograms else { throw InputError.invalid("请先记录一次体重") }
        if kind == .lose || kind == .gain {
            guard let age, age >= 18 else { throw InputError.invalid("需先确认成年；未成年或年龄未知时请使用只记录或维持模式") }
        }
        let target = kind == .record || kind == .maintain ? nil : unit.kilograms(try NumberInput.parse(targetText))
        if let target {
            guard (30...350).contains(target),
                  (kind == .lose ? target < current : target > current) else {
                throw InputError.invalid("请检查目标体重与变化方向")
            }
            if kind == .lose, let height = profile?.heightCM, let bmi = HealthMath.bmi(kg: target, heightCM: height), bmi < 18.5 {
                throw InputError.invalid("此目标不适合自动进度建议，请使用记录模式并咨询专业人士")
            }
        }
        try write { context in
            if let goal = healthGoal {
                goal.kindRaw = kind.rawValue; goal.startKG = current; goal.targetKG = target
                goal.startDate = now(); goal.updatedAt = now()
            } else {
                let goal = HealthGoal(kind: kind, start: current, target: target)
                goal.startDate = now(); goal.updatedAt = now()
                context.insert(goal)
            }
        }
    }

    func saveProfile(displayName: String, unit: WeightUnit, heightText: String, birth: Date?,
                     sex: BiologicalSex, activity: ActivityLevel, estimates: Bool) throws {
        guard let profile else { throw InputError.invalid("无法读取个人资料") }
        let height = heightText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try NumberInput.parse(heightText)
        if let height, !(50...250).contains(height) { throw InputError.invalid("请检查身高，单位为厘米") }
        if let birth, birth > now() { throw InputError.invalid("出生日期不能晚于今天") }
        let years = birth.flatMap { Calendar.current.dateComponents([.year], from: $0, to: now()).year }
        try write { _ in
            profile.displayName = String(displayName.prefix(60)); profile.weightUnitRaw = unit.rawValue
            profile.heightCM = height; profile.dateOfBirth = birth; profile.sexRaw = sex.rawValue
            profile.activityRaw = activity.rawValue; profile.estimatesEnabled = estimates; profile.updatedAt = now()
            if (years ?? 0) < 18, let goal = healthGoal, goal.kindRaw == "lose" || goal.kindRaw == "gain" {
                goal.kindRaw = "record"; goal.targetKG = nil; goal.updatedAt = now()
            }
        }
    }

    func createFamily(title: String) throws {
        let title = try name(title)
        guard data.families.isEmpty else { throw InputError.invalid("本地演示支持一个家庭组") }
        try write { context in
            let family = FamilyGroup(name: title)
            context.insert(family)
            context.insert(FamilyMember(groupID: family.id, name: L10n.text("我"), role: "owner"))
        }
    }
    func addMember(familyID: UUID, displayName: String) throws {
        let title = try name(displayName)
        guard data.families.contains(where: { $0.id == familyID }) else { throw InputError.invalid("家庭组不存在") }
        guard familyMemberNameAvailable(familyID: familyID, displayName: title) else { throw InputError.invalid("成员名称已存在（包括已归档成员）") }
        try write { $0.insert(FamilyMember(groupID: familyID, name: title)) }
    }

    func saveConfirmedMeal(_ meal: ConfirmedFoodMeal) throws {
        guard meal.source != .mock else { throw FoodRecognitionError.demoCannotPersist }
        try validDate(meal.date)
        // Confirmation IDs are stable across retries, never regenerated by the save action.
        if data.meals.contains(where: { $0.id == meal.id }) { return }
        try write { context in
            let record = FoodRecord(meal: meal, confirmedAt: now())
            context.insert(record)
            for value in meal.foods {
                let item = FoodItem(value: value)
                context.insert(item)
                item.record = record
            }
        }
    }

    func deleteMeal(_ meal: FoodRecord) throws {
        try write { $0.delete(meal) } // The owned food items are cascade-deleted.
    }
}