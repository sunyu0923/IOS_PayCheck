// File: c:\Users\YSun14\OneDrive - Rockwell Automation, Inc\Desktop\WorkProject\IOS_PayCheck\GoalPetTests\GoalPetTests.swift
// Purpose: Deterministic calculation and isolated, rollback-safe persistence regression tests.
// Dependencies: XCTest, Foundation, SwiftData, @testable GoalPet; iOS 17+, Swift 5.

import Foundation
import SwiftData
import XCTest
@testable import GoalPet

private enum TestDates {
    static func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) throws -> Date {
        let calendar = try Self.calendar()
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        )))
    }
}

final class GoalPetCalculationTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    func testMoneyParsesTenthsExactlyAsIntegerMinorUnits() throws {
        XCTAssertEqual(try Money.parse("0.1", currency: "USD", locale: posix), 10)
        XCTAssertEqual(try Money.parse("0.29", currency: "USD", locale: posix), 29)
        XCTAssertEqual(try Money.parse(" \n12.34\t", currency: "CNY", locale: posix), 1_234)
    }

    func testMoneyRejectsMalformedInput() {
        for input in ["", " ", "abc", "12abc", "1e2", "+1", "-1", ".5", "1.",
                      "1.234", "1,000", "1 000", "1..2", "$10", "NaN", "Infinity"] {
            XCTAssertThrowsError(try Money.parse(input, currency: "USD", locale: posix), input)
        }
    }

    func testJPYRejectsAllFractionalRepresentations() throws {
        XCTAssertEqual(try Money.parse("123", currency: "JPY", locale: posix), 123)
        for input in ["0.1", "1.0", "1.00", "123.45"] {
            XCTAssertThrowsError(try Money.parse(input, currency: "JPY", locale: posix), input)
        }
        XCTAssertThrowsError(try Money.parse("1,0", currency: "JPY", locale: Locale(identifier: "de_DE")))
    }

    func testMoneyParsesGermanDecimalSeparatorWithoutGrouping() throws {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(try Money.parse("0,1", currency: "EUR", locale: german), 10)
        XCTAssertEqual(try Money.parse("1234,56", currency: "EUR", locale: german), 123_456)
        for input in ["1.234,56", "1,234", "12,3,4"] {
            XCTAssertThrowsError(try Money.parse(input, currency: "EUR", locale: german), input)
        }
    }

    func testMoneyParsesArabicIndicDigitsWithEgyptianArabicLocale() throws {
        let arabic = Locale(identifier: "ar_EG")
        XCTAssertEqual(try Money.parse("١٢٣٤٫٥٦", currency: "USD", locale: arabic), 123_456)
        XCTAssertEqual(try Money.parse("٠٫٢٩", currency: "CNY", locale: arabic), 29)
        XCTAssertEqual(try Money.parse("١٢٣", currency: "JPY", locale: arabic), 123)
        XCTAssertThrowsError(try Money.parse("١٬٢٣٤٫٥٦", currency: "USD", locale: arabic))
        XCTAssertThrowsError(try Money.parse("١٫٢٣٤", currency: "USD", locale: arabic))
        XCTAssertThrowsError(try Money.parse("١٢٣٫٠", currency: "JPY", locale: arabic))
    }

    func testNumberInputParsesArabicIndicDigitsWithEgyptianArabicLocale() throws {
        let arabic = Locale(identifier: "ar_EG")
        XCTAssertEqual(NumberInput.asciiDigits("٠١٢٣٤٥٦٧٨٩"), "0123456789")
        XCTAssertEqual(try NumberInput.parse("٧٠٫١٢٣", locale: arabic), 70.123)
        XCTAssertEqual(try NumberInput.parse(" \n١٧٥\t", locale: arabic), 175)
        XCTAssertEqual(try NumberInput.parse("٠", locale: arabic), 0)
        XCTAssertThrowsError(try NumberInput.parse("١٬٧٥٠", locale: arabic))
        XCTAssertThrowsError(try NumberInput.parse("٧٠٫١٫٢", locale: arabic))
    }

    func testMoneyEnforcesZeroMinimumAndMaximumLimits() throws {
        XCTAssertThrowsError(try Money.parse("0", currency: "USD", locale: posix))
        XCTAssertEqual(try Money.parse("0", currency: "USD", allowZero: true, locale: posix), 0)
        XCTAssertEqual(try Money.parse("0.01", currency: "USD", locale: posix), 1)
        XCTAssertEqual(try Money.parse("1000000000.00", currency: "USD", locale: posix), Money.maximum)
        XCTAssertThrowsError(try Money.parse("1000000000.01", currency: "USD", locale: posix))
        XCTAssertEqual(try Money.parse("100000000000", currency: "JPY", locale: posix), Money.maximum)
        XCTAssertThrowsError(try Money.parse("100000000001", currency: "JPY", locale: posix))
        XCTAssertThrowsError(try Money.parse(String(repeating: "9", count: 100), currency: "USD", locale: posix))
    }

    func testMoneyRejectsUnsupportedCurrency() {
        XCTAssertThrowsError(try Money.parse("10", currency: "XYZ", locale: posix))
    }

    func testMoneyAdditionDetectsOverflowInBothDirections() throws {
        XCTAssertEqual(try Money.add(10, 20), 30)
        XCTAssertEqual(try Money.add(10, -10), 0)
        XCTAssertThrowsError(try Money.add(Int64.max, 1))
        XCTAssertThrowsError(try Money.add(Int64.min, -1))
    }

    func testBMIUsesHeightInMetersAndRejectsInvalidMeasurements() throws {
        XCTAssertEqual(try XCTUnwrap(HealthMath.bmi(kg: 70, heightCM: 175)), 22.857142857, accuracy: 0.000001)
        for kg in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertNil(HealthMath.bmi(kg: kg, heightCM: 175))
        }
        for height in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertNil(HealthMath.bmi(kg: 70, heightCM: height))
        }
    }

    func testBMRProvidesRangeForUnspecifiedSexAndPointEstimatesOtherwise() throws {
        let unknown = try XCTUnwrap(HealthMath.bmr(kg: 70, heightCM: 175, age: 30, sex: .unspecified))
        let male = try XCTUnwrap(HealthMath.bmr(kg: 70, heightCM: 175, age: 30, sex: .male))
        let female = try XCTUnwrap(HealthMath.bmr(kg: 70, heightCM: 175, age: 30, sex: .female))
        XCTAssertEqual(unknown.lowerBound, 1_482.75, accuracy: 0.000001)
        XCTAssertEqual(unknown.upperBound, 1_648.75, accuracy: 0.000001)
        XCTAssertEqual(male, 1_648.75...1_648.75)
        XCTAssertEqual(female, 1_482.75...1_482.75)
    }

    func testBMRRejectsUnderageAndOutOfRangeInputs() {
        for sex in BiologicalSex.allCases {
            for age in [-1, 0, 17, 101] {
                XCTAssertNil(HealthMath.bmr(kg: 70, heightCM: 175, age: age, sex: sex))
            }
            XCTAssertNotNil(HealthMath.bmr(kg: 70, heightCM: 175, age: 18, sex: sex))
        }
        XCTAssertNil(HealthMath.bmr(kg: 29, heightCM: 175, age: 30, sex: .unspecified))
        XCTAssertNil(HealthMath.bmr(kg: 351, heightCM: 175, age: 30, sex: .unspecified))
        XCTAssertNil(HealthMath.bmr(kg: 70, heightCM: 119, age: 30, sex: .unspecified))
        XCTAssertNil(HealthMath.bmr(kg: 70, heightCM: 231, age: 30, sex: .unspecified))
        XCTAssertNil(HealthMath.bmr(kg: .nan, heightCM: 175, age: 30, sex: .unspecified))
        XCTAssertNil(HealthMath.bmr(kg: 70, heightCM: .infinity, age: 30, sex: .unspecified))
    }

    func testTDEEPreservesBothUnknownSexBounds() throws {
        let bmr = try XCTUnwrap(HealthMath.bmr(kg: 70, heightCM: 175, age: 30, sex: .unspecified))
        let tdee = HealthMath.tdee(bmr: bmr, activity: .moderate)
        XCTAssertEqual(tdee.lowerBound, 2_298.2625, accuracy: 0.000001)
        XCTAssertEqual(tdee.upperBound, 2_555.5625, accuracy: 0.000001)
    }

    func testSavingsProgressClampsAndHandlesZeroTarget() {
        XCTAssertEqual(GoalMath.savings(current: -10, target: 100), 0)
        XCTAssertEqual(GoalMath.savings(current: 0, target: 100), 0)
        XCTAssertEqual(GoalMath.savings(current: 25, target: 100), 0.25)
        XCTAssertEqual(GoalMath.savings(current: 150, target: 100), 1)
        XCTAssertEqual(GoalMath.savings(current: 100, target: 0), 0)
        XCTAssertEqual(GoalMath.savings(current: 100, target: -1), 0)
    }

    func testWeightProgressHandlesFlatTargetsAndClampsBothDirections() throws {
        XCTAssertNil(GoalMath.weight(start: 70, target: 70, current: 70))
        XCTAssertNil(GoalMath.weight(start: 70, target: 70, current: 75))
        XCTAssertNil(GoalMath.weight(start: .nan, target: 60, current: 65))
        XCTAssertNil(GoalMath.weight(start: 70, target: .infinity, current: 65))
        XCTAssertNil(GoalMath.weight(start: 70, target: 60, current: .nan))
        XCTAssertEqual(try XCTUnwrap(GoalMath.weight(start: 80, target: 60, current: 70)), 0.5)
        XCTAssertEqual(try XCTUnwrap(GoalMath.weight(start: 80, target: 60, current: 90)), 0)
        XCTAssertEqual(try XCTUnwrap(GoalMath.weight(start: 80, target: 60, current: 50)), 1)
        XCTAssertEqual(try XCTUnwrap(GoalMath.weight(start: 60, target: 80, current: 70)), 0.5)
        XCTAssertEqual(try XCTUnwrap(GoalMath.weight(start: 60, target: 80, current: 50)), 0)
        XCTAssertEqual(try XCTUnwrap(GoalMath.weight(start: 60, target: 80, current: 90)), 1)
    }

    func testJanuaryBeforeStartDayUsesPreviousDecember() throws {
        let calendar = try TestDates.calendar()
        let interval = try XCTUnwrap(BudgetCalendar.interval(
            containing: try TestDates.date(2026, 1, 1), startDay: 15, calendar: calendar
        ))
        XCTAssertEqual(interval.start, try TestDates.date(2025, 12, 15))
        XCTAssertEqual(interval.end, try TestDates.date(2026, 1, 15))
    }

    func testJanuaryStartBoundaryBeginsNewBudgetPeriod() throws {
        let calendar = try TestDates.calendar()
        let start = try TestDates.date(2026, 1, 15)
        let previous = try XCTUnwrap(BudgetCalendar.interval(
            containing: start.addingTimeInterval(-1), startDay: 15, calendar: calendar
        ))
        let current = try XCTUnwrap(BudgetCalendar.interval(containing: start, startDay: 15, calendar: calendar))
        XCTAssertEqual(previous.end, start)
        XCTAssertEqual(current.start, start)
        XCTAssertEqual(current.end, try TestDates.date(2026, 2, 15))
    }

    func testDecemberEndIsExclusiveAndRollsIntoNextYear() throws {
        let calendar = try TestDates.calendar()
        let interval = try XCTUnwrap(BudgetCalendar.interval(
            containing: try TestDates.date(2026, 12, 31, hour: 23), startDay: 1, calendar: calendar
        ))
        XCTAssertEqual(interval.start, try TestDates.date(2026, 12, 1))
        XCTAssertEqual(interval.end, try TestDates.date(2027, 1, 1))
        // DateInterval.contains is not the ledger's half-open membership rule.
        let candidates = [interval.start.addingTimeInterval(-1), interval.start,
                          interval.end.addingTimeInterval(-1), interval.end]
        XCTAssertEqual(candidates.filter { $0 >= interval.start && $0 < interval.end },
                       [interval.start, interval.end.addingTimeInterval(-1)])
        let next = try XCTUnwrap(BudgetCalendar.interval(containing: interval.end, startDay: 1, calendar: calendar))
        XCTAssertEqual(next.start, interval.end)
        XCTAssertEqual(next.end, try TestDates.date(2027, 2, 1))
        let offset = try XCTUnwrap(BudgetCalendar.interval(
            containing: try TestDates.date(2026, 12, 28), startDay: 28, calendar: calendar
        ))
        XCTAssertEqual(offset.start, try TestDates.date(2026, 12, 28))
        XCTAssertEqual(offset.end, try TestDates.date(2027, 1, 28))
    }

    func testBudgetRejectsUnsupportedStartDays() throws {
        let calendar = try TestDates.calendar()
        let date = try TestDates.date(2026, 1, 1)
        for startDay in [-1, 0, 29, 31] {
            XCTAssertNil(BudgetCalendar.interval(containing: date, startDay: startDay, calendar: calendar))
        }
    }

    func testDailyWeightsAverageSameDaySamplesAndSortChronologically() throws {
        let calendar = try TestDates.calendar()
        let points = [
            WeightPoint(date: try TestDates.date(2026, 1, 2, hour: 12), kg: 70),
            WeightPoint(date: try TestDates.date(2026, 1, 1, hour: 20), kg: 90),
            WeightPoint(date: try TestDates.date(2026, 1, 1, hour: 8), kg: 70)
        ]
        let days = HealthMath.daily(points, calendar: calendar)
        XCTAssertEqual(days.map(\.date), try [TestDates.date(2026, 1, 1), TestDates.date(2026, 1, 2)])
        XCTAssertEqual(days.map(\.kg), [80, 70])
    }

    func testRollingAverageWeightsDaysEquallyNotIndividualSamples() throws {
        let calendar = try TestDates.calendar()
        let points = [
            WeightPoint(date: try TestDates.date(2026, 1, 3), kg: 60),
            WeightPoint(date: try TestDates.date(2026, 1, 1, hour: 8), kg: 70),
            WeightPoint(date: try TestDates.date(2026, 1, 2), kg: 70),
            WeightPoint(date: try TestDates.date(2026, 1, 1, hour: 20), kg: 90)
        ]
        let averages = HealthMath.movingAverage(points, calendar: calendar)
        XCTAssertEqual(averages.count, 1)
        let point = try XCTUnwrap(averages.first)
        XCTAssertEqual(point.date, try TestDates.date(2026, 1, 3))
        XCTAssertEqual(point.kg, 70, accuracy: 0.000001)
    }

    func testRollingAverageRequiresThreeDistinctCoveredDays() throws {
        let calendar = try TestDates.calendar()
        let first = try TestDates.date(2026, 1, 1)
        let duplicates = [WeightPoint(date: first, kg: 60),
                          WeightPoint(date: first.addingTimeInterval(3600), kg: 62),
                          WeightPoint(date: first.addingTimeInterval(7200), kg: 64)]
        XCTAssertTrue(HealthMath.movingAverage([], calendar: calendar).isEmpty)
        XCTAssertTrue(HealthMath.movingAverage(duplicates, calendar: calendar).isEmpty)
        let sparse = duplicates + [WeightPoint(date: try TestDates.date(2026, 1, 2), kg: 70),
                                   WeightPoint(date: try TestDates.date(2026, 1, 8), kg: 80)]
        XCTAssertTrue(HealthMath.movingAverage(sparse, calendar: calendar).isEmpty)
    }

    func testRollingAverageAllowsMissingDaysAndExcludesSamplesOlderThanSevenDayWindow() throws {
        let calendar = try TestDates.calendar()
        let points = [
            WeightPoint(date: try TestDates.date(2026, 1, 1), kg: 60),
            WeightPoint(date: try TestDates.date(2026, 1, 4), kg: 72),
            WeightPoint(date: try TestDates.date(2026, 1, 7), kg: 78),
            WeightPoint(date: try TestDates.date(2026, 1, 8), kg: 84)
        ]
        let averages = HealthMath.movingAverage(points, calendar: calendar)
        XCTAssertEqual(averages.map(\.date), try [TestDates.date(2026, 1, 7), TestDates.date(2026, 1, 8)])
        XCTAssertEqual(averages.map(\.kg), [70, 78])
    }
}

// No shared store, global locale/time-zone mutation, or actor-isolated XCTest lifecycle override.
@MainActor
private struct InMemoryFixture {
    let repository: LocalRepository
    let model: AppViewModel
    let now: Date

    init() throws {
        let instant = try TestDates.date(2026, 6, 15, hour: 12)
        let container = try LocalRepository.makeContainer(inMemory: true)
        let repository = try LocalRepository(container: container)
        self.repository = repository
        now = instant
        model = try AppViewModel(repository: repository, now: { instant })
    }

    // A new repository/context verifies saved state rather than just observable model references.
    func reloaded() throws -> AppViewModel {
        let instant = now
        return try AppViewModel(repository: LocalRepository(container: repository.container), now: { instant })
    }

    func saveTransaction(id: UUID, amount: String = "10", kind: TransactionKind = .expense) throws {
        try model.saveTransaction(id: id, kind: kind, amountText: amount,
                                  category: XCTUnwrap(kind.categories.first), date: now, note: "Test transaction")
    }

    func makeGoal(familyID: UUID? = nil, initial: String = "0") throws -> SavingsGoal {
        try model.saveGoal(title: "Test goal", targetText: "1000", initialText: initial,
                           date: now, familyID: familyID)
        return try XCTUnwrap(model.data.goals.first { $0.familyGroupID == familyID })
    }

    func contribute(id: UUID = UUID(), goal: SavingsGoal, memberID: UUID? = nil,
                    amount: String = "100", withdrawal: Bool = false) throws {
        try model.saveContribution(id: id, goal: goal, memberID: memberID, amountText: amount,
                                   withdrawal: withdrawal, date: now, note: "Test contribution")
    }

    func saveProfile(birth: Date?, estimates: Bool = true) throws {
        try model.saveProfile(displayName: "Test user", unit: .kg, heightText: "175", birth: birth,
                              sex: .unspecified, activity: .moderate, estimates: estimates)
    }
}

final class GoalPetPersistenceTests: XCTestCase {
    @MainActor
    func testInMemoryRepositoriesAreIsolatedAndSeedOnlyOperationalDefaults() throws {
        let first = try InMemoryFixture()
        let second = try InMemoryFixture()
        XCTAssertEqual(first.model.data.profiles.count, 1)
        XCTAssertEqual(first.model.data.accounts.count, 1)
        XCTAssertTrue(first.model.data.transactions.isEmpty)
        XCTAssertTrue(first.model.data.goals.isEmpty)
        XCTAssertTrue(first.model.data.weights.isEmpty)
        try first.saveTransaction(id: UUID())
        XCTAssertEqual(try first.reloaded().data.transactions.count, 1)
        XCTAssertTrue(try second.reloaded().data.transactions.isEmpty)
    }

    @MainActor
    func testTransactionSavePersistsValidatedFields() throws {
        let fixture = try InMemoryFixture()
        let id = UUID()
        try fixture.saveTransaction(id: id, amount: "12")
        let saved = try XCTUnwrap(try fixture.reloaded().data.transactions.first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.amountMinor, 1_200)
        XCTAssertEqual(saved.kindRaw, TransactionKind.expense.rawValue)
        XCTAssertEqual(saved.currency, "CNY")
        XCTAssertEqual(saved.category, try XCTUnwrap(TransactionKind.expense.categories.first))
        XCTAssertEqual(saved.accountID, try XCTUnwrap(fixture.model.data.accounts.first).id)
        XCTAssertEqual(saved.date, fixture.now)
        XCTAssertEqual(saved.note, "Test transaction")
        XCTAssertNil(saved.deletedAt)
    }

    @MainActor
    func testTransactionEditAndRepeatedIDNeverInsertDuplicateRows() throws {
        let fixture = try InMemoryFixture()
        let id = UUID()
        try fixture.saveTransaction(id: id)
        try fixture.saveTransaction(id: id)
        XCTAssertEqual(fixture.model.data.transactions.count, 1)
        let category = try XCTUnwrap(TransactionKind.income.categories.first)
        let editedDate = fixture.now.addingTimeInterval(-3600)
        try fixture.model.saveTransaction(id: id, kind: .income, amountText: "25", category: category,
                                          date: editedDate, note: "Edited")
        let model = try fixture.reloaded()
        XCTAssertEqual(model.data.transactions.count, 1)
        let edited = try XCTUnwrap(model.data.transactions.first)
        XCTAssertEqual(edited.id, id)
        XCTAssertEqual(edited.kindRaw, TransactionKind.income.rawValue)
        XCTAssertEqual(edited.amountMinor, 2_500)
        XCTAssertEqual(edited.category, category)
        XCTAssertEqual(edited.date, editedDate)
        XCTAssertEqual(edited.note, "Edited")
        XCTAssertEqual(edited.updatedAt, fixture.now)
    }

    @MainActor
    func testTransactionEditRetainsSeededJPYCurrencyAccountAndMinorUnitScale() throws {
        let fixture = try InMemoryFixture()
        let defaultAccount = try XCTUnwrap(fixture.model.data.accounts.first)
        let account = FinancialAccount(currency: "JPY")
        let id = UUID()
        let category = try XCTUnwrap(TransactionKind.expense.categories.first)
        let amount = try Money.parse("123", currency: "JPY", locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertEqual(amount, 123)
        // Seed a foreign-currency transaction without changing the default CNY profile/account.
        _ = try fixture.repository.commit { context in
            context.insert(account)
            context.insert(LedgerTransaction(id: id, kind: .expense, amount: amount, currency: "JPY",
                                             category: category, accountID: account.id,
                                             date: fixture.now, note: "Seeded JPY"))
        }
        let model = try fixture.reloaded()
        XCTAssertEqual(model.currency, "CNY")
        XCTAssertEqual(try XCTUnwrap(model.data.transactions.first).amountMinor, 123)
        try model.saveTransaction(id: id, kind: .expense, amountText: "456", category: category,
                                  date: fixture.now, note: "Edited JPY")
        let saved = try fixture.reloaded()
        XCTAssertEqual(saved.data.transactions.count, 1)
        let edited = try XCTUnwrap(saved.data.transactions.first)
        XCTAssertEqual(edited.id, id)
        XCTAssertEqual(edited.currency, "JPY")
        XCTAssertEqual(edited.accountID, account.id)
        XCTAssertNotEqual(edited.accountID, defaultAccount.id)
        XCTAssertEqual(edited.amountMinor, 456)
        XCTAssertNotEqual(edited.amountMinor, 45_600)
        XCTAssertEqual(edited.note, "Edited JPY")
        XCTAssertEqual(edited.updatedAt, fixture.now)
        XCTAssertEqual(saved.currency, "CNY")
        XCTAssertEqual(try XCTUnwrap(saved.data.accounts.first { $0.id == defaultAccount.id }).currency, "CNY")
    }

    @MainActor
    func testTransactionSoftDeleteAndRestorePersistWithoutLosingRecord() throws {
        let fixture = try InMemoryFixture()
        try fixture.saveTransaction(id: UUID())
        let record = try XCTUnwrap(fixture.model.activeTransactions.first)
        try fixture.model.setDeleted(record, deleted: true)
        let deleted = try fixture.reloaded()
        XCTAssertTrue(deleted.activeTransactions.isEmpty)
        XCTAssertEqual(deleted.data.transactions.count, 1)
        let deletedRecord = try XCTUnwrap(deleted.data.transactions.first)
        XCTAssertEqual(deletedRecord.deletedAt, fixture.now)
        XCTAssertEqual(deleted.total(.expense), 0)
        try deleted.setDeleted(deletedRecord, deleted: false)
        let restored = try fixture.reloaded()
        XCTAssertEqual(restored.activeTransactions.map(\.id), [record.id])
        XCTAssertNil(try XCTUnwrap(restored.activeTransactions.first).deletedAt)
        XCTAssertEqual(restored.total(.expense), 1_000)
    }

    @MainActor
    func testEditingDeletedTransactionIsRejectedWithoutChangingSavedAmount() throws {
        let fixture = try InMemoryFixture()
        let id = UUID()
        try fixture.saveTransaction(id: id)
        let record = try XCTUnwrap(fixture.model.activeTransactions.first)
        try fixture.model.setDeleted(record, deleted: true)
        XCTAssertThrowsError(try fixture.saveTransaction(id: id, amount: "99"))
        let saved = try XCTUnwrap(try fixture.reloaded().data.transactions.first)
        XCTAssertEqual(saved.amountMinor, 1_000)
        XCTAssertEqual(saved.deletedAt, fixture.now)
    }

    @MainActor
    func testInvalidTransactionInputLeavesStoreEmpty() throws {
        let fixture = try InMemoryFixture()
        XCTAssertThrowsError(try fixture.saveTransaction(id: UUID(), amount: "-1"))
        XCTAssertThrowsError(try fixture.model.saveTransaction(
            id: UUID(), kind: .expense, amountText: "10", category: "invalid category", date: fixture.now, note: ""
        ))
        let category = try XCTUnwrap(TransactionKind.expense.categories.first)
        XCTAssertThrowsError(try fixture.model.saveTransaction(
            id: UUID(), kind: .expense, amountText: "10", category: category,
            date: fixture.now.addingTimeInterval(1), note: ""
        ))
        XCTAssertTrue(fixture.model.data.transactions.isEmpty)
        XCTAssertTrue(try fixture.reloaded().data.transactions.isEmpty)
    }

    @MainActor
    func testBudgetTotalsIncludeStartButExcludeEndDeletedRowsAndOtherCurrencies() throws {
        let fixture = try InMemoryFixture()
        try fixture.model.setBudget(amountText: "100", startDay: 15)
        // AppViewModel uses Calendar.current; derive boundaries instead of assuming its zone/calendar.
        let period = try XCTUnwrap(fixture.model.period)
        let account = try XCTUnwrap(fixture.model.data.accounts.first)
        let category = try XCTUnwrap(TransactionKind.expense.categories.first)
        _ = try fixture.repository.commit { context in
            for (date, amount) in [(period.start.addingTimeInterval(-1), Int64(10_000)),
                                   (period.start, Int64(100)),
                                   (period.end.addingTimeInterval(-1), Int64(200)),
                                   (period.end, Int64(20_000))] {
                context.insert(LedgerTransaction(kind: .expense, amount: amount, currency: "CNY",
                                                 category: category, accountID: account.id, date: date, note: "Boundary"))
            }
            let deleted = LedgerTransaction(kind: .expense, amount: 30_000, currency: "CNY",
                                            category: category, accountID: account.id, date: period.start, note: "Deleted")
            deleted.deletedAt = fixture.now
            context.insert(deleted)
            context.insert(LedgerTransaction(kind: .expense, amount: 40_000, currency: "USD",
                                             category: category, accountID: account.id, date: period.start, note: "Other currency"))
            context.insert(LedgerTransaction(kind: .income, amount: 500, currency: "CNY",
                                             category: "工资", accountID: account.id, date: period.start, note: "Income"))
        }
        let model = try fixture.reloaded()
        XCTAssertEqual(model.total(.expense), 300)
        XCTAssertEqual(model.total(.income), 500)
    }

    @MainActor
    func testRepositoryRollsBackUpdateInsertAndDeleteWhenMutationThrows() throws {
        let fixture = try InMemoryFixture()
        try fixture.saveTransaction(id: UUID())
        try fixture.model.setBudget(amountText: "100", startDay: 1)
        let record = try XCTUnwrap(fixture.model.data.transactions.first)
        let budget = try XCTUnwrap(fixture.model.budget)
        let budgetID = budget.id
        // Validation belongs to the mutation/view model, not to LocalRepository itself.
        XCTAssertThrowsError(try fixture.repository.commit { context in
            record.amountMinor = -1
            context.insert(WeightRecord(kilograms: 70, date: fixture.now, note: "Must roll back"))
            context.delete(budget)
            throw InputError.invalid("Invalid test mutation")
        }) { error in
            XCTAssertTrue(error is InputError)
        }
        let sameContext = try fixture.repository.load()
        XCTAssertEqual(try XCTUnwrap(sameContext.transactions.first).amountMinor, 1_000)
        XCTAssertTrue(sameContext.weights.isEmpty)
        XCTAssertEqual(sameContext.budgets.map(\.id), [budgetID])
        let saved = try fixture.reloaded()
        XCTAssertEqual(try XCTUnwrap(saved.data.transactions.first).amountMinor, 1_000)
        XCTAssertTrue(saved.data.weights.isEmpty)
        XCTAssertEqual(saved.data.budgets.map(\.id), [budgetID])
        try fixture.saveTransaction(id: record.id, amount: "20")
        XCTAssertEqual(try XCTUnwrap(try fixture.reloaded().data.transactions.first).amountMinor, 2_000)
    }

    @MainActor
    func testContributionRetryWithSameIDAndRequestIsIdempotentAcrossReload() throws {
        let fixture = try InMemoryFixture()
        let goal = try fixture.makeGoal(initial: "10")
        let operationID = UUID()
        try fixture.contribute(id: operationID, goal: goal, amount: "25")
        try fixture.contribute(id: operationID, goal: goal, amount: "25")
        XCTAssertEqual(fixture.model.contributions(for: goal).count, 1)
        XCTAssertEqual(fixture.model.balance(goal), 3_500)
        let reloaded = try fixture.reloaded()
        let savedGoal = try XCTUnwrap(reloaded.personalGoals.first)
        try reloaded.saveContribution(id: operationID, goal: savedGoal, memberID: nil, amountText: "25",
                                      withdrawal: false, date: fixture.now, note: "Test contribution")
        let persisted = try fixture.reloaded()
        let contribution = try XCTUnwrap(persisted.data.contributions.first)
        XCTAssertEqual(persisted.data.contributions.count, 1)
        XCTAssertEqual(contribution.id, operationID)
        XCTAssertEqual(contribution.goalID, goal.id)
        XCTAssertEqual(contribution.signedMinor, 2_500)
        XCTAssertEqual(contribution.date, fixture.now)
        XCTAssertEqual(contribution.note, "Test contribution")
        XCTAssertEqual(persisted.balance(try XCTUnwrap(persisted.personalGoals.first)), 3_500)
    }

    @MainActor
    func testWithdrawalCannotMakeBalanceNegativeButCanReachZero() throws {
        let fixture = try InMemoryFixture()
        let goal = try fixture.makeGoal(initial: "50")
        XCTAssertThrowsError(try fixture.contribute(goal: goal, amount: "51", withdrawal: true))
        XCTAssertEqual(fixture.model.balance(goal), 5_000)
        XCTAssertTrue(try fixture.reloaded().data.contributions.isEmpty)
        try fixture.contribute(goal: goal, amount: "50", withdrawal: true)
        XCTAssertEqual(fixture.model.balance(goal), 0)
        XCTAssertThrowsError(try fixture.contribute(goal: goal, amount: "1", withdrawal: true))
        let saved = try fixture.reloaded()
        XCTAssertEqual(saved.data.contributions.count, 1)
        XCTAssertEqual(saved.balance(try XCTUnwrap(saved.personalGoals.first)), 0)
    }

    @MainActor
    func testDeletingDepositAfterWithdrawalIsBlocked() throws {
        let fixture = try InMemoryFixture()
        let goal = try fixture.makeGoal()
        let depositID = UUID()
        try fixture.contribute(id: depositID, goal: goal)
        try fixture.contribute(goal: goal, amount: "60", withdrawal: true)
        let deposit = try XCTUnwrap(fixture.model.data.contributions.first { $0.id == depositID })
        XCTAssertThrowsError(try fixture.model.setDeleted(deposit, deleted: true))
        XCTAssertNil(deposit.deletedAt)
        XCTAssertEqual(fixture.model.balance(goal), 4_000)
        let saved = try fixture.reloaded()
        XCTAssertEqual(saved.data.contributions.count, 2)
        XCTAssertTrue(saved.data.contributions.allSatisfy { $0.deletedAt == nil })
        XCTAssertEqual(saved.balance(try XCTUnwrap(saved.personalGoals.first)), 4_000)
    }

    @MainActor
    func testDeletedContributionRecoveryRespectsBalanceAndCanRestoreInSafeOrder() throws {
        let fixture = try InMemoryFixture()
        let goal = try fixture.makeGoal()
        let depositID = UUID()
        let withdrawalID = UUID()
        try fixture.contribute(id: depositID, goal: goal)
        try fixture.contribute(id: withdrawalID, goal: goal, amount: "60", withdrawal: true)
        let deposit = try XCTUnwrap(fixture.model.data.contributions.first { $0.id == depositID })
        let withdrawal = try XCTUnwrap(fixture.model.data.contributions.first { $0.id == withdrawalID })
        try fixture.model.setDeleted(withdrawal, deleted: true)
        XCTAssertEqual(fixture.model.balance(goal), 10_000)
        try fixture.model.setDeleted(deposit, deleted: true)
        try fixture.model.setDeleted(deposit, deleted: true)
        XCTAssertEqual(fixture.model.balance(goal), 0)
        XCTAssertTrue(fixture.model.contributions(for: goal).isEmpty)
        XCTAssertEqual(fixture.model.contributions(for: goal, includeDeleted: true).count, 2)
        let model = try fixture.reloaded()
        let savedGoal = try XCTUnwrap(model.personalGoals.first)
        let savedDeposit = try XCTUnwrap(model.data.contributions.first { $0.id == depositID })
        let savedWithdrawal = try XCTUnwrap(model.data.contributions.first { $0.id == withdrawalID })
        XCTAssertEqual(savedDeposit.deletedAt, fixture.now)
        XCTAssertEqual(savedWithdrawal.deletedAt, fixture.now)
        XCTAssertThrowsError(try model.setDeleted(savedWithdrawal, deleted: false))
        XCTAssertNotNil(savedWithdrawal.deletedAt)
        XCTAssertEqual(model.balance(savedGoal), 0)
        try model.setDeleted(savedDeposit, deleted: false)
        try model.setDeleted(savedDeposit, deleted: false)
        XCTAssertEqual(model.balance(savedGoal), 10_000)
        try model.setDeleted(savedWithdrawal, deleted: false)
        let restored = try fixture.reloaded()
        XCTAssertEqual(restored.balance(try XCTUnwrap(restored.personalGoals.first)), 4_000)
        XCTAssertEqual(restored.data.contributions.count, 2)
        XCTAssertTrue(restored.data.contributions.allSatisfy { $0.deletedAt == nil })
    }

    @MainActor
    func testRetryOfDeletedContributionDoesNotDuplicateOrRestoreIt() throws {
        let fixture = try InMemoryFixture()
        let goal = try fixture.makeGoal()
        let id = UUID()
        try fixture.contribute(id: id, goal: goal)
        let contribution = try XCTUnwrap(fixture.model.data.contributions.first)
        try fixture.model.setDeleted(contribution, deleted: true)
        try fixture.contribute(id: id, goal: goal)
        let saved = try fixture.reloaded()
        XCTAssertEqual(saved.data.contributions.count, 1)
        XCTAssertNotNil(try XCTUnwrap(saved.data.contributions.first).deletedAt)
        XCTAssertEqual(saved.balance(try XCTUnwrap(saved.personalGoals.first)), 0)
    }

    @MainActor
    func testFamilyContributionRejectsMissingForeignAndArchivedMembers() throws {
        let fixture = try InMemoryFixture()
        try fixture.model.createFamily(title: "Family A")
        let family = try XCTUnwrap(fixture.model.data.families.first)
        let owner = try XCTUnwrap(fixture.model.members(in: family.id).first)
        let goal = try fixture.makeGoal(familyID: family.id)
        // Seed a second group directly: the UI deliberately permits only one local family.
        let foreignFamily = FamilyGroup(name: "Family B")
        let foreignMember = FamilyMember(groupID: foreignFamily.id, name: "Foreign member")
        let archivedMember = FamilyMember(groupID: family.id, name: "Archived member")
        archivedMember.isArchived = true
        _ = try fixture.repository.commit { context in
            context.insert(foreignFamily)
            context.insert(foreignMember)
            context.insert(archivedMember)
        }
        let model = try fixture.reloaded()
        let savedGoal = try XCTUnwrap(model.data.goals.first { $0.id == goal.id })
        let invalidMemberIDs: [UUID?] = [nil, foreignMember.id, archivedMember.id]
        for memberID in invalidMemberIDs {
            XCTAssertThrowsError(try model.saveContribution(
                id: UUID(), goal: savedGoal, memberID: memberID, amountText: "10",
                withdrawal: false, date: fixture.now, note: "Invalid member"
            ))
        }
        XCTAssertEqual(model.members(in: family.id).map(\.id), [owner.id])
        XCTAssertTrue(try fixture.reloaded().data.contributions.isEmpty)
        try model.saveContribution(id: UUID(), goal: savedGoal, memberID: owner.id, amountText: "10",
                                   withdrawal: false, date: fixture.now, note: "Valid member")
        let saved = try fixture.reloaded()
        XCTAssertEqual(saved.data.contributions.count, 1)
        XCTAssertEqual(try XCTUnwrap(saved.data.contributions.first).memberID, owner.id)
    }

    @MainActor
    func testFamilyAndPersonalGoalsKeepContributionsAndPrivateRecordsIsolated() throws {
        let fixture = try InMemoryFixture()
        let transactionID = UUID()
        let weightID = UUID()
        try fixture.saveTransaction(id: transactionID)
        try fixture.model.saveWeight(id: weightID, value: "70", date: fixture.now, note: "Private weight")
        let personal = try fixture.makeGoal(initial: "5")
        try fixture.model.createFamily(title: "Shared planning")
        let family = try XCTUnwrap(fixture.model.data.families.first)
        let member = try XCTUnwrap(fixture.model.members(in: family.id).first)
        let shared = try fixture.makeGoal(familyID: family.id, initial: "10")
        XCTAssertThrowsError(try fixture.contribute(goal: personal, memberID: member.id))
        let personalID = UUID()
        let sharedID = UUID()
        try fixture.contribute(id: personalID, goal: personal, amount: "20")
        try fixture.contribute(id: sharedID, goal: shared, memberID: member.id, amount: "30")
        let model = try fixture.reloaded()
        let savedPersonal = try XCTUnwrap(model.personalGoals.first)
        let savedShared = try XCTUnwrap(model.data.goals.first { $0.id == shared.id })
        XCTAssertEqual(model.personalGoals.map(\.id), [personal.id])
        XCTAssertEqual(model.balance(savedPersonal), 2_500)
        XCTAssertEqual(model.balance(savedShared), 4_000)
        XCTAssertEqual(model.contributions(for: savedPersonal).map(\.id), [personalID])
        XCTAssertEqual(model.contributions(for: savedShared).map(\.id), [sharedID])
        XCTAssertNil(try XCTUnwrap(model.contributions(for: savedPersonal).first).memberID)
        XCTAssertEqual(model.data.transactions.map(\.id), [transactionID])
        XCTAssertEqual(model.total(.expense), 1_000)
        XCTAssertEqual(model.data.weights.map(\.id), [weightID])
        XCTAssertEqual(try XCTUnwrap(model.latestWeight).kilograms, 70)
        XCTAssertEqual(try XCTUnwrap(model.latestWeight).note, "Private weight")
    }

    @MainActor
    func testWeightSaveEditRepeatedIDAndDeletePersist() throws {
        let fixture = try InMemoryFixture()
        let id = UUID()
        try fixture.model.saveWeight(id: id, value: "70", date: fixture.now, note: "First")
        try fixture.model.saveWeight(id: id, value: "70", date: fixture.now, note: "First")
        let editedDate = fixture.now.addingTimeInterval(-3600)
        try fixture.model.saveWeight(id: id, value: "71", date: editedDate, note: "Edited")
        let model = try fixture.reloaded()
        XCTAssertEqual(model.data.weights.count, 1)
        let weight = try XCTUnwrap(model.latestWeight)
        XCTAssertEqual(weight.id, id)
        XCTAssertEqual(weight.kilograms, 71)
        XCTAssertEqual(weight.date, editedDate)
        XCTAssertEqual(weight.note, "Edited")
        XCTAssertEqual(weight.updatedAt, fixture.now)
        try model.deleteWeight(weight)
        XCTAssertTrue(try fixture.reloaded().data.weights.isEmpty)
    }

    @MainActor
    func testWeightNoteOnlyEditPreservesExactMeasurementAcrossReload() throws {
        let fixture = try InMemoryFixture()
        let id = UUID()
        let kilograms = 70.123
        _ = try fixture.repository.commit { context in
            context.insert(WeightRecord(id: id, kilograms: kilograms, date: fixture.now, note: "Original note"))
        }
        let model = try fixture.reloaded()
        let original = try XCTUnwrap(model.latestWeight)
        XCTAssertEqual(original.kilograms, kilograms)
        // The editor displays only two decimal places; an unchanged field must not round storage.
        let displayedValue = NumberInput.format(model.unit.display(original.kilograms))
        XCTAssertNotEqual(try NumberInput.parse(displayedValue), kilograms)
        try model.saveWeight(id: id, value: displayedValue, date: original.date,
                             note: "Edited note only", preserveMeasurement: true)
        let saved = try fixture.reloaded()
        XCTAssertEqual(saved.data.weights.count, 1)
        let edited = try XCTUnwrap(saved.latestWeight)
        XCTAssertEqual(edited.id, id)
        XCTAssertEqual(edited.kilograms, 70.123)
        XCTAssertEqual(edited.kilograms.bitPattern, kilograms.bitPattern)
        XCTAssertEqual(edited.date, fixture.now)
        XCTAssertEqual(edited.note, "Edited note only")
        XCTAssertEqual(edited.updatedAt, fixture.now)
    }

    @MainActor
    func testInvalidWeightIsRejectedWithoutSaving() throws {
        let fixture = try InMemoryFixture()
        for input in ["abc", "-1", "9", "501", "NaN"] {
            XCTAssertThrowsError(try fixture.model.saveWeight(id: UUID(), value: input, date: fixture.now, note: ""))
        }
        XCTAssertThrowsError(try fixture.model.saveWeight(
            id: UUID(), value: "70", date: fixture.now.addingTimeInterval(1), note: ""
        ))
        XCTAssertTrue(try fixture.reloaded().data.weights.isEmpty)
    }

    @MainActor
    func testHealthGoalRequiresWeightAndSupportsOptionalTargetInRecordAndMaintainModes() throws {
        let fixture = try InMemoryFixture()
        XCTAssertThrowsError(try fixture.model.saveHealthGoal(kind: .record, targetText: ""))
        try fixture.model.saveWeight(id: UUID(), value: "70", date: fixture.now, note: "")
        try fixture.model.saveHealthGoal(kind: .record, targetText: "")
        let recordGoal = try XCTUnwrap(fixture.model.healthGoal)
        let id = recordGoal.id
        XCTAssertEqual(recordGoal.kindRaw, HealthGoalKind.record.rawValue)
        XCTAssertEqual(recordGoal.startKG, 70)
        XCTAssertNil(recordGoal.targetKG)
        try fixture.model.saveHealthGoal(kind: .maintain, targetText: "not needed")
        let model = try fixture.reloaded()
        XCTAssertEqual(model.data.healthGoals.count, 1)
        let goal = try XCTUnwrap(model.healthGoal)
        XCTAssertEqual(goal.id, id)
        XCTAssertEqual(goal.kindRaw, HealthGoalKind.maintain.rawValue)
        XCTAssertNil(goal.targetKG)
        XCTAssertEqual(goal.startKG, 70)
        XCTAssertEqual(goal.startDate, fixture.now)
    }

    @MainActor
    func testAdultHealthGoalSavesTargetAndClearsItWhenSwitchingToRecord() throws {
        let fixture = try InMemoryFixture()
        try fixture.saveProfile(birth: TestDates.date(1990, 1, 1))
        try fixture.model.saveWeight(id: UUID(), value: "70", date: fixture.now, note: "")
        try fixture.model.saveHealthGoal(kind: .lose, targetText: "65")
        let saved = try fixture.reloaded()
        let goal = try XCTUnwrap(saved.healthGoal)
        XCTAssertEqual(goal.kindRaw, HealthGoalKind.lose.rawValue)
        XCTAssertEqual(try XCTUnwrap(goal.targetKG), 65)
        XCTAssertEqual(goal.startKG, 70)
        XCTAssertThrowsError(try saved.saveHealthGoal(kind: .lose, targetText: "75"))
        XCTAssertThrowsError(try saved.saveHealthGoal(kind: .lose, targetText: "40"))
        XCTAssertThrowsError(try saved.saveHealthGoal(kind: .gain, targetText: "65"))
        XCTAssertEqual(try XCTUnwrap(saved.healthGoal?.targetKG), 65)
        try saved.saveHealthGoal(kind: .gain, targetText: "75")
        XCTAssertEqual(try XCTUnwrap(saved.healthGoal?.targetKG), 75)
        try saved.saveHealthGoal(kind: .record, targetText: "")
        let restored = try fixture.reloaded()
        XCTAssertEqual(restored.data.healthGoals.count, 1)
        XCTAssertEqual(try XCTUnwrap(restored.healthGoal).id, goal.id)
        XCTAssertNil(try XCTUnwrap(restored.healthGoal).targetKG)
    }

    @MainActor
    func testUnknownAgeAndUnderageBlockBMRAndTDEEAndDirectionalGoals() throws {
        let fixture = try InMemoryFixture()
        try fixture.model.saveWeight(id: UUID(), value: "70", date: fixture.now, note: "")
        let births: [Date?] = [nil, try TestDates.date(2010, 1, 1)]
        for birth in births {
            try fixture.saveProfile(birth: birth)
            XCTAssertNil(fixture.model.bmr)
            XCTAssertNil(fixture.model.tdee)
            XCTAssertThrowsError(try fixture.model.saveHealthGoal(kind: .lose, targetText: "65"))
            XCTAssertThrowsError(try fixture.model.saveHealthGoal(kind: .gain, targetText: "75"))
            try fixture.model.saveHealthGoal(kind: .record, targetText: "")
            try fixture.model.saveHealthGoal(kind: .maintain, targetText: "")
            XCTAssertNil(try XCTUnwrap(fixture.model.healthGoal).targetKG)
        }
        let model = try fixture.reloaded()
        XCTAssertNil(model.bmr)
        XCTAssertNil(model.tdee)
        XCTAssertEqual(try XCTUnwrap(model.healthGoal).kindRaw, HealthGoalKind.maintain.rawValue)
    }

    @MainActor
    func testAdultUnspecifiedSexEstimatesRespectOptInAndPersistProfile() throws {
        let fixture = try InMemoryFixture()
        let birth = try TestDates.date(1990, 1, 1)
        try fixture.model.saveWeight(id: UUID(), value: "70", date: fixture.now, note: "")
        try fixture.saveProfile(birth: birth, estimates: false)
        XCTAssertNil(fixture.model.bmr)
        XCTAssertNil(fixture.model.tdee)
        try fixture.saveProfile(birth: birth)
        let model = try fixture.reloaded()
        let profile = try XCTUnwrap(model.profile)
        XCTAssertEqual(profile.displayName, "Test user")
        XCTAssertEqual(profile.heightCM, 175)
        XCTAssertEqual(profile.dateOfBirth, birth)
        XCTAssertEqual(profile.sexRaw, BiologicalSex.unspecified.rawValue)
        XCTAssertTrue(profile.estimatesEnabled)
        let bmr = try XCTUnwrap(model.bmr)
        let expected = try XCTUnwrap(HealthMath.bmr(
            kg: 70, heightCM: 175, age: try XCTUnwrap(model.age), sex: .unspecified
        ))
        XCTAssertEqual(bmr, expected)
        XCTAssertLessThan(bmr.lowerBound, bmr.upperBound)
        let tdee = try XCTUnwrap(model.tdee)
        XCTAssertEqual(tdee.lowerBound, bmr.lowerBound * 1.55, accuracy: 0.000001)
        XCTAssertEqual(tdee.upperBound, bmr.upperBound * 1.55, accuracy: 0.000001)
    }

    @MainActor
    func testChangingProfileToUnderageOrUnknownAgeClearsDirectionalHealthTarget() throws {
        let fixture = try InMemoryFixture()
        try fixture.model.saveWeight(id: UUID(), value: "70", date: fixture.now, note: "")
        let adultBirth = try TestDates.date(1990, 1, 1)
        let restrictedBirths: [Date?] = [try TestDates.date(2010, 1, 1), nil]
        for birth in restrictedBirths {
            try fixture.saveProfile(birth: adultBirth)
            try fixture.model.saveHealthGoal(kind: .lose, targetText: "65")
            try fixture.saveProfile(birth: birth)
            let model = try fixture.reloaded()
            XCTAssertEqual(try XCTUnwrap(model.healthGoal).kindRaw, HealthGoalKind.record.rawValue)
            XCTAssertNil(try XCTUnwrap(model.healthGoal).targetKG)
            XCTAssertNil(model.bmr)
            XCTAssertNil(model.tdee)
        }
    }
}