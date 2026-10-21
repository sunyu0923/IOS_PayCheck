// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Models/Models.swift
// Purpose: Local MVP persistence models. Dependencies: Foundation, SwiftData.
import Foundation
import SwiftData

enum TransactionKind: String, CaseIterable, Identifiable {
    case expense, income
    var id: String { rawValue }
    var title: String { L10n.text(self == .expense ? "支出" : "收入") }
    var categories: [String] {
        self == .expense
            ? ["餐饮", "交通", "购物", "居住", "娱乐", "医疗健康", "学习", "旅行", "宠物", "人情", "订阅服务", "其他"]
            : ["工资", "奖金", "报销", "投资收益", "兼职", "礼金", "退款", "其他"]
    }
}

enum WeightUnit: String, CaseIterable, Identifiable {
    case kg, lb
    var id: String { rawValue }
    func display(_ kg: Double) -> Double { self == .kg ? kg : kg * 2.2046226218 }
    func kilograms(_ value: Double) -> Double { self == .kg ? value : value / 2.2046226218 }
}

enum HealthGoalKind: String, CaseIterable, Identifiable {
    case record, lose, gain, maintain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .record: return L10n.text("只记录")
        case .lose: return L10n.text("减重")
        case .gain: return L10n.text("增重")
        case .maintain: return L10n.text("维持体重")
        }
    }
}

enum BiologicalSex: String, CaseIterable, Identifiable {
    case unspecified, male, female
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unspecified: return L10n.text("不提供")
        case .male: return L10n.text("男性")
        case .female: return L10n.text("女性")
        }
    }
}

enum ActivityLevel: String, CaseIterable, Identifiable {
    case sedentary, light, moderate, high, veryHigh
    var id: String { rawValue }
    var factor: Double {
        switch self {
        case .sedentary: return 1.2
        case .light: return 1.375
        case .moderate: return 1.55
        case .high: return 1.725
        case .veryHigh: return 1.9
        }
    }
    var title: String {
        switch self {
        case .sedentary: return L10n.text("久坐")
        case .light: return L10n.text("轻度活动")
        case .moderate: return L10n.text("中度活动")
        case .high: return L10n.text("高度活动")
        case .veryHigh: return L10n.text("非常高活动量")
        }
    }
}

@Model final class UserProfile {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var currency: String
    var weightUnitRaw: String
    var heightCM: Double?
    var dateOfBirth: Date?
    var sexRaw: String
    var activityRaw: String
    var estimatesEnabled: Bool
    var updatedAt: Date
    init() {
        id = UUID(); displayName = ""; currency = "CNY"; weightUnitRaw = "kg"
        sexRaw = "unspecified"; activityRaw = "sedentary"; estimatesEnabled = false
        updatedAt = .now
    }
}

@Model final class FinancialAccount {
    @Attribute(.unique) var id: UUID
    var name: String
    var currency: String
    var isArchived: Bool
    init(currency: String) {
        id = UUID(); name = "默认账户"; self.currency = currency; isArchived = false
    }
}

@Model final class LedgerTransaction {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var amountMinor: Int64
    var currency: String
    var category: String
    var accountID: UUID
    var date: Date
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    init(id: UUID = UUID(), kind: TransactionKind, amount: Int64, currency: String,
         category: String, accountID: UUID, date: Date, note: String) {
        self.id = id; kindRaw = kind.rawValue; amountMinor = amount; self.currency = currency
        self.category = category; self.accountID = accountID; self.date = date; self.note = note
        createdAt = .now; updatedAt = .now
    }
}

@Model final class Budget {
    @Attribute(.unique) var id: UUID
    var amountMinor: Int64
    var currency: String
    var startDay: Int
    init(amount: Int64, currency: String, startDay: Int) {
        id = UUID(); amountMinor = amount; self.currency = currency; self.startDay = startDay
    }
}

// UUID references deliberately avoid cross-domain cascade deletion.
// Family records below are LOCAL planning data, not authenticated memberships.
@Model final class FamilyGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    init(name: String) { id = UUID(); self.name = name; createdAt = .now }
}

@Model final class FamilyMember {
    @Attribute(.unique) var id: UUID
    var groupID: UUID
    var displayName: String
    var roleRaw: String
    var isArchived: Bool
    init(groupID: UUID, name: String, role: String = "member") {
        id = UUID(); self.groupID = groupID; displayName = name; roleRaw = role; isArchived = false
    }
}

@Model final class SavingsGoal {
    @Attribute(.unique) var id: UUID
    var name: String
    var targetMinor: Int64
    var initialMinor: Int64
    var currency: String
    var targetDate: Date
    var familyGroupID: UUID?
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    init(name: String, target: Int64, initial: Int64, currency: String,
         targetDate: Date, familyGroupID: UUID? = nil) {
        id = UUID(); self.name = name; targetMinor = target; initialMinor = initial
        self.currency = currency; self.targetDate = targetDate; self.familyGroupID = familyGroupID
        statusRaw = "active"; createdAt = .now; updatedAt = .now
    }
}

@Model final class SavingsContribution {
    @Attribute(.unique) var id: UUID
    var goalID: UUID
    var memberID: UUID?
    var signedMinor: Int64
    var date: Date
    var note: String
    var deletedAt: Date?
    init(id: UUID = UUID(), goalID: UUID, memberID: UUID?, signedMinor: Int64, date: Date, note: String) {
        self.id = id; self.goalID = goalID; self.memberID = memberID
        self.signedMinor = signedMinor; self.date = date; self.note = note
    }
}

@Model final class WeightRecord {
    @Attribute(.unique) var id: UUID
    var kilograms: Double
    var date: Date
    var note: String
    var updatedAt: Date
    init(id: UUID = UUID(), kilograms: Double, date: Date, note: String) {
        self.id = id; self.kilograms = kilograms; self.date = date; self.note = note; updatedAt = .now
    }
}

@Model final class HealthGoal {
    @Attribute(.unique) var id: UUID
    var statusRaw: String = "active"
    var kindRaw: String
    var startKG: Double
    var targetKG: Double?
    var startDate: Date
    var updatedAt: Date
    init(kind: HealthGoalKind, start: Double, target: Double?) {
        id = UUID(); kindRaw = kind.rawValue; startKG = start; targetKG = target
        startDate = .now; updatedAt = .now
    }
}