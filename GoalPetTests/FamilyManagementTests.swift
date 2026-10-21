import Foundation
import SwiftData
import XCTest
@testable import GoalPet

@MainActor
private struct FamilyManagementFixture {
    let repository: LocalRepository
    let model: AppViewModel
    let instant = Date(timeIntervalSince1970: 1_800_000_000)

    init(seed: (ModelContext) throws -> Void = { _ in }) throws {
        let container = try LocalRepository.makeContainer(inMemory: true)
        repository = try LocalRepository(container: container)
        _ = try repository.commit(seed)
        let date = instant
        model = try AppViewModel(repository: repository, now: { date })
    }

    func reloaded() throws -> AppViewModel {
        let date = instant
        return try AppViewModel(repository: LocalRepository(container: repository.container), now: { date })
    }

    func createFamilyAndMember() throws -> (FamilyGroup, FamilyMember) {
        try model.createFamily(title: "Home")
        let family = try XCTUnwrap(model.data.families.first)
        try model.addMember(familyID: family.id, displayName: "Alex")
        let member = try XCTUnwrap(model.data.members.first { $0.displayName == "Alex" })
        return (family, member)
    }
}

final class FamilyManagementTests: XCTestCase {
    @MainActor
    func testRenameFamilyTrimsPersistsAndKeepsIdentity() throws {
        let fixture = try FamilyManagementFixture()
        let (family, _) = try fixture.createFamilyAndMember()
        let created = family.createdAt
        try fixture.model.renameFamily(id: family.id, title: " \nNew Home\t ")
        let saved = try XCTUnwrap(try fixture.reloaded().data.families.first)
        XCTAssertEqual(saved.id, family.id)
        XCTAssertEqual(saved.name, "New Home")
        XCTAssertEqual(saved.createdAt, created)
    }

    @MainActor
    func testRenameValidationRejectsEmptyAndOverlongButAcceptsSixtyCharacters() throws {
        let fixture = try FamilyManagementFixture()
        let (family, member) = try fixture.createFamilyAndMember()
        for invalid in ["", " \n\t", String(repeating: "a", count: 61)] {
            XCTAssertThrowsError(try fixture.model.renameFamily(id: family.id, title: invalid))
            XCTAssertThrowsError(try fixture.model.renameFamilyMember(id: member.id, displayName: invalid))
        }
        XCTAssertEqual(family.name, "Home")
        XCTAssertEqual(member.displayName, "Alex")
        let limit = String(repeating: "家", count: 60)
        try fixture.model.renameFamily(id: family.id, title: limit)
        try fixture.model.renameFamilyMember(id: member.id, displayName: limit)
        let reloaded = try fixture.reloaded()
        XCTAssertEqual(reloaded.data.families.first?.name, limit)
        XCTAssertEqual(reloaded.data.members.first { $0.id == member.id }?.displayName, limit)
    }

    @MainActor
    func testRenameMemberTrimsAndAllowsNormalizedSelfName() throws {
        let fixture = try FamilyManagementFixture()
        let (family, member) = try fixture.createFamilyAndMember()
        try fixture.model.renameFamilyMember(id: member.id, displayName: " \nÁLEX\t")
        let reloaded = try fixture.reloaded()
        let saved = try XCTUnwrap(reloaded.data.members.first { $0.id == member.id })
        XCTAssertEqual(saved.displayName, "ÁLEX")
        XCTAssertEqual(saved.groupID, family.id)
        XCTAssertEqual(saved.roleRaw, "member")
        XCTAssertFalse(saved.isArchived)
    }

    @MainActor
    func testNormalizedDuplicatesRejectedByAddAndRenameIncludingArchivedMembers() throws {
        let fixture = try FamilyManagementFixture()
        let (family, member) = try fixture.createFamilyAndMember()
        try fixture.model.renameFamilyMember(id: member.id, displayName: "José")
        try fixture.model.addMember(familyID: family.id, displayName: "Sam")
        let other = try XCTUnwrap(fixture.model.data.members.first { $0.displayName == "Sam" })
        for archived in [false, true] {
            try fixture.model.setFamilyMemberArchived(id: member.id, archived: archived)
            for duplicate in ["JOSE", " jose ", "Jose\u{301}"] {
                XCTAssertFalse(fixture.model.familyMemberNameAvailable(familyID: family.id, displayName: duplicate))
                XCTAssertThrowsError(try fixture.model.addMember(familyID: family.id, displayName: duplicate))
                XCTAssertThrowsError(try fixture.model.renameFamilyMember(id: other.id, displayName: duplicate))
            }
        }
        let reloaded = try fixture.reloaded()
        XCTAssertEqual(reloaded.data.members.count, 3)
        XCTAssertEqual(reloaded.data.members.first { $0.id == other.id }?.displayName, "Sam")
    }

    @MainActor
    func testNameAvailabilityValidatesScopeAndInput() throws {
        let fixture = try FamilyManagementFixture()
        let (family, member) = try fixture.createFamilyAndMember()
        XCTAssertFalse(fixture.model.familyMemberNameAvailable(familyID: UUID(), displayName: "Free"))
        XCTAssertFalse(fixture.model.familyMemberNameAvailable(familyID: family.id, displayName: " \n"))
        XCTAssertFalse(fixture.model.familyMemberNameAvailable(familyID: family.id, displayName: String(repeating: "x", count: 61)))
        XCTAssertTrue(fixture.model.familyMemberNameAvailable(familyID: family.id, displayName: " ALEX ",
                                                             excludingMemberID: member.id))
    }

    @MainActor
    func testOwnerLabelCannotBeArchivedEvenAfterRename() throws {
        let fixture = try FamilyManagementFixture()
        let (family, _) = try fixture.createFamilyAndMember()
        let owner = try XCTUnwrap(fixture.model.members(in: family.id).first { $0.roleRaw == "owner" })
        try fixture.model.renameFamilyMember(id: owner.id, displayName: "Creator")
        XCTAssertThrowsError(try fixture.model.setFamilyMemberArchived(id: owner.id, archived: true))
        let saved = try XCTUnwrap(try fixture.reloaded().data.members.first { $0.id == owner.id })
        XCTAssertFalse(saved.isArchived)
        XCTAssertEqual(saved.roleRaw, "owner")
        XCTAssertEqual(saved.displayName, "Creator")
    }

    @MainActor
    func testArchiveAndRestoreAreIdempotentAndPreserveHistory() throws {
        let fixture = try FamilyManagementFixture()
        let (family, member) = try fixture.createFamilyAndMember()
        try fixture.model.saveGoal(title: "Trip", targetText: "100", initialText: "10",
                                   date: fixture.instant, familyID: family.id)
        let goal = try XCTUnwrap(fixture.model.data.goals.first)
        let depositID = UUID()
        try fixture.model.saveContribution(id: depositID, goal: goal, memberID: member.id,
                                           amountText: "20", withdrawal: false, date: fixture.instant, note: "deposit")
        // Retrying the same form must not count the deposit twice.
        try fixture.model.saveContribution(id: depositID, goal: goal, memberID: member.id,
                                           amountText: "20", withdrawal: false, date: fixture.instant, note: "deposit")
        try fixture.model.saveContribution(id: UUID(), goal: goal, memberID: member.id,
                                           amountText: "5", withdrawal: true, date: fixture.instant, note: "withdrawal")
        for _ in 0..<2 { try fixture.model.setFamilyMemberArchived(id: member.id, archived: true) }
        XCTAssertFalse(fixture.model.members(in: family.id).contains { $0.id == member.id })
        XCTAssertFalse(fixture.model.familyMembers(in: family.id).contains { $0.id == member.id })
        XCTAssertTrue(fixture.model.familyMembers(in: family.id, includeArchived: true).contains { $0.id == member.id })
        XCTAssertEqual(fixture.model.memberContributionTotal(familyID: family.id, memberID: member.id, currency: "CNY"), 1_500)
        XCTAssertThrowsError(try fixture.model.saveContribution(id: UUID(), goal: goal, memberID: member.id,
                                                               amountText: "1", withdrawal: false,
                                                               date: fixture.instant, note: "blocked"))
        try fixture.model.renameFamilyMember(id: member.id, displayName: "Archived Alex")
        XCTAssertEqual(fixture.model.memberName(member.id), "Archived Alex")
        for _ in 0..<2 { try fixture.model.setFamilyMemberArchived(id: member.id, archived: false) }
        let reloaded = try fixture.reloaded()
        XCTAssertTrue(reloaded.members(in: family.id).contains { $0.id == member.id })
        let savedGoal = try XCTUnwrap(reloaded.data.goals.first { $0.id == goal.id })
        XCTAssertEqual(reloaded.balance(savedGoal), 2_500)
        XCTAssertEqual(reloaded.data.contributions.count, 2)
        XCTAssertEqual(Set(reloaded.data.contributions.map(\.note)), Set(["deposit", "withdrawal"]))
        XCTAssertTrue(reloaded.data.contributions.allSatisfy { $0.memberID == member.id && $0.deletedAt == nil })
        try reloaded.saveContribution(id: UUID(), goal: savedGoal, memberID: member.id,
                                      amountText: "1", withdrawal: false, date: fixture.instant, note: "restored")
        XCTAssertEqual(reloaded.memberContributionTotal(familyID: family.id, memberID: member.id, currency: "CNY"), 1_600)
    }

    @MainActor
    func testRestoreRejectsLegacyCollisionUntilRenamed() throws {
        let family = FamilyGroup(name: "Legacy")
        let archived = FamilyMember(groupID: family.id, name: "José")
        archived.isArchived = true
        let fixture = try FamilyManagementFixture { context in
            context.insert(family)
            context.insert(archived)
            context.insert(FamilyMember(groupID: family.id, name: "JOSE"))
        }
        XCTAssertThrowsError(try fixture.model.setFamilyMemberArchived(id: archived.id, archived: false))
        XCTAssertEqual(try fixture.reloaded().data.members.first { $0.id == archived.id }?.isArchived, true)
        try fixture.model.renameFamilyMember(id: archived.id, displayName: "José Two")
        try fixture.model.setFamilyMemberArchived(id: archived.id, archived: false)
        XCTAssertEqual(try fixture.reloaded().data.members.first { $0.id == archived.id }?.isArchived, false)
    }

    @MainActor
    func testRestoreAlsoRejectsCollisionWithAnotherArchivedLabel() throws {
        let family = FamilyGroup(name: "Legacy")
        let first = FamilyMember(groupID: family.id, name: "Sam")
        let second = FamilyMember(groupID: family.id, name: "SAM")
        first.isArchived = true
        second.isArchived = true
        let fixture = try FamilyManagementFixture { context in
            context.insert(family); context.insert(first); context.insert(second)
        }
        XCTAssertThrowsError(try fixture.model.setFamilyMemberArchived(id: first.id, archived: false))
        XCTAssertTrue(try fixture.reloaded().data.members.allSatisfy(\.isArchived))
    }

    @MainActor
    func testUnknownIDsThrowWithoutCreatingOrChangingRecords() throws {
        let fixture = try FamilyManagementFixture()
        _ = try fixture.createFamilyAndMember()
        let missing = UUID()
        XCTAssertThrowsError(try fixture.model.renameFamily(id: missing, title: "Ghost"))
        XCTAssertThrowsError(try fixture.model.renameFamilyMember(id: missing, displayName: "Ghost"))
        XCTAssertThrowsError(try fixture.model.setFamilyMemberArchived(id: missing, archived: true))
        XCTAssertThrowsError(try fixture.model.setFamilyMemberArchived(id: missing, archived: false))
        let reloaded = try fixture.reloaded()
        XCTAssertEqual(reloaded.data.families.map(\.name), ["Home"])
        XCTAssertEqual(reloaded.data.members.count, 2)
        XCTAssertTrue(reloaded.data.members.allSatisfy { !$0.isArchived })
    }

    @MainActor
    func testOrphanedMemberCannotBeRenamedOrRestored() throws {
        let orphan = FamilyMember(groupID: UUID(), name: "Orphan")
        orphan.isArchived = true
        let fixture = try FamilyManagementFixture { $0.insert(orphan) }
        XCTAssertThrowsError(try fixture.model.renameFamilyMember(id: orphan.id, displayName: "New"))
        XCTAssertThrowsError(try fixture.model.setFamilyMemberArchived(id: orphan.id, archived: false))
        XCTAssertEqual(fixture.model.memberContributionTotal(familyID: orphan.groupID, memberID: orphan.id, currency: "CNY"), 0)
        let saved = try XCTUnwrap(try fixture.reloaded().data.members.first)
        XCTAssertEqual(saved.displayName, "Orphan")
        XCTAssertTrue(saved.isArchived)
    }

    @MainActor
    func testNamesAreUniqueWithinFamilyNotAcrossFamilies() throws {
        let first = FamilyGroup(name: "First")
        let second = FamilyGroup(name: "Second")
        let member = FamilyMember(groupID: second.id, name: "Other")
        let fixture = try FamilyManagementFixture { context in
            context.insert(first); context.insert(second)
            context.insert(FamilyMember(groupID: first.id, name: "José"))
            context.insert(member)
        }
        XCTAssertTrue(fixture.model.familyMemberNameAvailable(familyID: second.id, displayName: "JOSE"))
        try fixture.model.renameFamilyMember(id: member.id, displayName: "JOSE")
        XCTAssertEqual(try fixture.reloaded().data.members.first { $0.id == member.id }?.displayName, "JOSE")
    }

    @MainActor
    func testContributionTotalsScopeCurrencyFamilyMemberAndLiveHistory() throws {
        let family = FamilyGroup(name: "Home")
        let foreign = FamilyGroup(name: "Other")
        let member = FamilyMember(groupID: family.id, name: "Alex")
        let other = FamilyMember(groupID: family.id, name: "Sam")
        let outsider = FamilyMember(groupID: foreign.id, name: "Elsewhere")
        member.isArchived = true
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func goal(_ currency: String, familyID: UUID?) -> SavingsGoal {
            SavingsGoal(name: "Goal", target: 10_000, initial: 1_000, currency: currency,
                        targetDate: date, familyGroupID: familyID)
        }
        let cny = goal("CNY", familyID: family.id)
        let paused = goal("CNY", familyID: family.id)
        paused.statusRaw = "paused"
        let usd = goal("USD", familyID: family.id)
        let jpy = goal("JPY", familyID: family.id)
        let personal = goal("CNY", familyID: nil)
        let foreignGoal = goal("CNY", familyID: foreign.id)
        let fixture = try FamilyManagementFixture { context in
            context.insert(family); context.insert(foreign)
            context.insert(member); context.insert(other); context.insert(outsider)
            for value in [cny, paused, usd, jpy, personal, foreignGoal] { context.insert(value) }
            func record(_ goalID: UUID, _ memberID: UUID?, _ amount: Int64, deleted: Bool = false) {
                let value = SavingsContribution(goalID: goalID, memberID: memberID, signedMinor: amount,
                                                date: date, note: "fixture")
                if deleted { value.deletedAt = date }
                context.insert(value)
            }
            record(cny.id, member.id, 500)
            record(cny.id, member.id, -200)
            record(paused.id, member.id, 75)
            record(cny.id, member.id, 999, deleted: true)
            record(cny.id, member.id, -90, deleted: true)
            record(usd.id, member.id, 120)
            record(jpy.id, member.id, -25)
            record(personal.id, member.id, 888)
            record(foreignGoal.id, member.id, 777)
            record(UUID(), member.id, 666)
            record(cny.id, other.id, 444)
            record(cny.id, outsider.id, 333)
            record(cny.id, nil, 222)
        }
        let model = fixture.model
        XCTAssertEqual(model.memberContributionTotal(familyID: family.id, memberID: member.id, currency: "CNY"), 375)
        XCTAssertEqual(model.memberContributionTotal(familyID: family.id, memberID: member.id, currency: "USD"), 120)
        XCTAssertEqual(model.memberContributionTotal(familyID: family.id, memberID: member.id, currency: "JPY"), -25)
        XCTAssertEqual(model.memberContributionTotal(familyID: family.id, memberID: member.id, currency: "EUR"), 0)
        XCTAssertEqual(model.memberContributionTotal(familyID: family.id, memberID: other.id, currency: "CNY"), 444)
        XCTAssertEqual(model.memberContributionTotal(familyID: family.id, memberID: outsider.id, currency: "CNY"), 0)
        XCTAssertEqual(model.memberContributionTotal(familyID: foreign.id, memberID: member.id, currency: "CNY"), 0)
        XCTAssertEqual(model.memberContributionTotal(familyID: UUID(), memberID: member.id, currency: "CNY"), 0)
        XCTAssertEqual(model.memberContributionTotal(familyID: family.id, memberID: UUID(), currency: "CNY"), 0)
        XCTAssertEqual(try fixture.reloaded().data.contributions.count, 13)
    }
}
