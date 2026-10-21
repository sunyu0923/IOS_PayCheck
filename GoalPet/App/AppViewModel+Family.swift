// Local family labels only; all mutations use the repository-backed write boundary.
import Foundation

extension AppViewModel {
    func familyMemberNameAvailable(familyID: UUID, displayName: String,
                                   excludingMemberID: UUID? = nil) -> Bool {
        guard data.families.contains(where: { $0.id == familyID }),
              let candidate = try? name(displayName) else { return false }
        let key = normalizedFamilyMemberName(candidate)
        return !data.members.contains {
            $0.groupID == familyID && $0.id != excludingMemberID &&
            normalizedFamilyMemberName($0.displayName) == key
        }
    }

    private func normalizedFamilyMemberName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    func renameFamily(id: UUID, title: String) throws {
        let title = try name(title)
        try write { _ in
            guard let family = data.families.first(where: { $0.id == id }) else {
                throw InputError.invalid("家庭组不存在")
            }
            family.name = title
        }
    }

    func renameFamilyMember(id: UUID, displayName: String) throws {
        let title = try name(displayName)
        try write { _ in
            guard let member = data.members.first(where: { $0.id == id }),
                  data.families.contains(where: { $0.id == member.groupID }) else {
                throw InputError.invalid("成员标签或家庭组不存在")
            }
            guard familyMemberNameAvailable(familyID: member.groupID, displayName: title,
                                            excludingMemberID: id) else {
                throw InputError.invalid("成员名称已存在（包含已归档标签）")
            }
            member.displayName = title
        }
    }

    func setFamilyMemberArchived(id: UUID, archived: Bool) throws {
        try write { _ in
            guard let member = data.members.first(where: { $0.id == id }),
                  data.families.contains(where: { $0.id == member.groupID }) else {
                throw InputError.invalid("成员标签或家庭组不存在")
            }
            // A local data invariant, not an authorization or identity check.
            guard !archived || member.roleRaw != "owner" else {
                throw InputError.invalid("创建者标签不能归档")
            }
            if !archived {
                guard familyMemberNameAvailable(familyID: member.groupID, displayName: member.displayName,
                                                excludingMemberID: id) else {
                    throw InputError.invalid("成员名称已存在，请先重命名再恢复")
                }
            }
            member.isArchived = archived
        }
    }

    func familyMembers(in familyID: UUID, includeArchived: Bool = false) -> [FamilyMember] {
        data.members.filter { $0.groupID == familyID && (includeArchived || !$0.isArchived) }
            .sorted {
                if $0.isArchived != $1.isArchived { return !$0.isArchived }
                if $0.roleRaw == "owner", $1.roleRaw != "owner" { return true }
                if $1.roleRaw == "owner", $0.roleRaw != "owner" { return false }
                let lhs = normalizedFamilyMemberName($0.displayName)
                let rhs = normalizedFamilyMemberName($1.displayName)
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
            }
    }

    /// Net recorded contributions, including archived goals/members, never initial balances.
    /// Goal currency is authoritative; personal/foreign/orphaned/deleted records are excluded.
    func memberContributionTotal(familyID: UUID, memberID: UUID, currency: String) -> Int64 {
        guard data.families.contains(where: { $0.id == familyID }),
              data.members.contains(where: { $0.id == memberID && $0.groupID == familyID }) else { return 0 }
        let goalIDs = Set(data.goals.filter {
            $0.familyGroupID == familyID && $0.currency == currency
        }.map(\.id))
        return data.contributions.filter {
            $0.memberID == memberID && $0.deletedAt == nil && goalIDs.contains($0.goalID)
        }.reduce(Int64(0)) { $0 + $1.signedMinor }
    }
}
