// Path: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Core/Calculations.swift
// Purpose: Pure, testable money, calendar and health calculations. Dependencies: Models, L10n.
import Foundation

enum InputError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return L10n.text(message) }
    }
}

enum Money {
    static let currencies = ["CNY", "USD", "EUR", "GBP", "JPY"]
    static let maximum: Int64 = 100_000_000_000
    static func scale(_ currency: String) -> Int64 { currency == "JPY" ? 1 : 100 }

    // Full-string parsing: reject grouping, exponent notation and excess precision.
    static func parse(_ input: String, currency: String, allowZero: Bool = false,
                      locale: Locale = .current) throws -> Int64 {
        guard currencies.contains(currency) else { throw InputError.invalid("不支持此货币") }
        let separator = locale.decimalSeparator ?? "."
        let text = NumberInput.asciiDigits(input.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: separator, with: ".")
        let digits = currency == "JPY" ? 0 : 2
        let pattern = digits == 0 ? "^[0-9]+$" : "^[0-9]+(?:\\.[0-9]{1,2})?$"
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw InputError.invalid("请输入有效金额，不要使用千位分隔符")
        }
        let minor = value * Decimal(scale(currency))
        guard minor <= Decimal(maximum), minor >= (allowZero ? 0 : 1) else {
            throw InputError.invalid("金额超出允许范围")
        }
        return NSDecimalNumber(decimal: minor).int64Value
    }

    static func format(_ minor: Int64, currency: String) -> String {
        let value = Decimal(minor) / Decimal(scale(currency))
        return value.formatted(.currency(code: currency))
    }

    static func input(_ minor: Int64, currency: String) -> String {
        let value = Decimal(minor) / Decimal(scale(currency))
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...(currency == "JPY" ? 0 : 2))))
    }

    static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw InputError.invalid("金额合计超出范围") }
        return result.partialValue
    }
}

enum NumberInput {
    static func asciiDigits(_ input: String) -> String {
        input.map { character in
            if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
               let digit = character.wholeNumberValue, (0...9).contains(digit) {
                return String(digit)
            }
            return String(character)
        }.joined()
    }
    static func parse(_ input: String, locale: Locale = .current) throws -> Double {
        let value = asciiDigits(input.trimmingCharacters(in: .whitespacesAndNewlines))
            .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard value.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let result = Double(value), result.isFinite else {
            throw InputError.invalid("请输入有效数字")
        }
        return result
    }
    static func format(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }
}

enum GoalMath {
    static func savings(current: Int64, target: Int64) -> Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, Double(current) / Double(target)))
    }
    static func weight(start: Double, target: Double, current: Double) -> Double? {
        guard start.isFinite, target.isFinite, current.isFinite, start != target else { return nil }
        return min(1, max(0, (current - start) / (target - start)))
    }
    static let milestones: [Double] = [0.10, 0.25, 0.50, 0.75, 1]
}

enum BudgetCalendar {
    static func interval(containing date: Date, startDay: Int, calendar: Calendar = .current) -> DateInterval? {
        guard (1...28).contains(startDay), let month = calendar.dateInterval(of: .month, for: date),
              let candidate = calendar.date(byAdding: .day, value: startDay - 1, to: month.start) else { return nil }
        let start: Date
        if date < candidate {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: candidate) else { return nil }
            start = previous
        } else { start = candidate }
        guard let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }
}

struct WeightPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let kg: Double
}

enum HealthMath {
    static func bmi(kg: Double, heightCM: Double) -> Double? {
        guard kg.isFinite, heightCM.isFinite, kg > 0, heightCM > 0 else { return nil }
        return kg / pow(heightCM / 100, 2)
    }

    // Adult-only descriptive estimates. No calorie deficit or dietary prescription.
    static func bmr(kg: Double, heightCM: Double, age: Int, sex: BiologicalSex) -> ClosedRange<Double>? {
        guard kg.isFinite, heightCM.isFinite, (30...350).contains(kg),
              (120...230).contains(heightCM), (18...100).contains(age) else { return nil }
        let base = 10 * kg + 6.25 * heightCM - 5 * Double(age)
        switch sex {
        case .male: return (base + 5)...(base + 5)
        case .female: return (base - 161)...(base - 161)
        case .unspecified: return (base - 161)...(base + 5)
        }
    }
    static func tdee(bmr: ClosedRange<Double>, activity: ActivityLevel) -> ClosedRange<Double> {
        (bmr.lowerBound * activity.factor)...(bmr.upperBound * activity.factor)
    }
    static func daily(_ records: [WeightPoint], calendar: Calendar = .current) -> [WeightPoint] {
        Dictionary(grouping: records, by: { calendar.startOfDay(for: $0.date) })
            .map { day, values in WeightPoint(date: day, kg: values.map(\.kg).reduce(0, +) / Double(values.count)) }
            .sorted { $0.date < $1.date }
    }
    static func movingAverage(_ records: [WeightPoint], calendar: Calendar = .current) -> [WeightPoint] {
        let days = daily(records, calendar: calendar)
        return days.compactMap { day in
            guard let lower = calendar.date(byAdding: .day, value: -6, to: day.date) else { return nil }
            let window = days.filter { $0.date >= lower && $0.date <= day.date }
            guard window.count >= 3 else { return nil }
            return WeightPoint(date: day.date, kg: window.map(\.kg).reduce(0, +) / Double(window.count))
        }
    }
}