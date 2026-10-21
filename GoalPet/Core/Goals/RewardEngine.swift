// iOS 17 / Swift 5. Auto-award domain service; no SwiftUI or claim action.
import Foundation
import SwiftData

enum RewardEngineError: Error {
    case invalidCandidate
    case experienceOverflow
}

@MainActor enum RewardEngine {
    // Stable species IDs verified against PetCatalog.all; no view-layer dependency.
    private static let unlocks: [(xp: Int, petID: String)] = [(20, "cat"), (100, "whale"), (250, "bird")]
    private static let petIDs: Set<String> = ["cat", "whale", "bird"]

    /// REQUIRED repository integration (including startup): disable autosave, mutate,
    /// load a snapshot INCLUDING pending changes and reward events, evaluate, reconcile,
    /// reload the returned snapshot, then save ONCE. Roll back the same ModelContext on
    /// ANY error. Never save the source before reconciling. Call on EVERY mutation.
    /// This method intentionally never saves, starts a nested transaction, or rolls back
    /// the caller's work. One serial MainActor writer/context must own the store; unique
    /// keys alone are not a cross-context/cloud concurrency or backup-rollback protocol.
    static func reconcile(_ candidates: [RewardCandidate], in context: ModelContext, now: Date) throws {
        // Validate the entire batch before inserting anything. Callers supply trusted
        // GoalEngine candidates; this is not an endpoint accepting arbitrary client XP.
        for candidate in candidates {
            guard !candidate.key.isEmpty, candidate.xp >= 0,
                  !candidate.key.hasPrefix("source:"), !candidate.key.hasPrefix("pet:"),
                  candidate.petID.map({ petIDs.contains($0) }) ?? true,
                  candidate.sourceKey.map({ $0.hasPrefix("source:") && $0.count > 7 }) ?? true else {
                throw RewardEngineError.invalidCandidate
            }
        }
        var descriptor = FetchDescriptor<RewardEvent>()
        descriptor.includePendingChanges = true
        let existing = try context.fetch(descriptor)
        var keys = Set(existing.map(\.key))
        var total = experience(existing)
        // Plan the full append before writing, including overflow checks and receipts.
        var additions: [RewardCandidate] = []
        for candidate in candidates {
            guard !keys.contains(candidate.key) else { continue }
            if let source = candidate.sourceKey, keys.contains(source) { continue }
            let sum = total.addingReportingOverflow(candidate.xp)
            guard !sum.overflow else { throw RewardEngineError.experienceOverflow }
            total = sum.partialValue
            keys.insert(candidate.key)
            additions.append(candidate)
            if let source = candidate.sourceKey {
                keys.insert(source)
                additions.append(RewardCandidate(key: source, title: "记录奖励凭据", xp: 0))
            }
        }
        // Also repairs missing unlock rows at startup when there are no new candidates.
        for unlock in unlocks where total >= unlock.xp {
            let key = "pet:\(unlock.petID)"
            if keys.insert(key).inserted {
                additions.append(RewardCandidate(key: key, title: "解锁 \(unlock.petID)", xp: 0,
                                                  petID: unlock.petID))
            }
        }
        for candidate in additions {
            context.insert(RewardEvent(key: candidate.key, title: candidate.title, xp: candidate.xp,
                                       petID: candidate.petID, earnedAt: now))
        }
    }

    /// Lifetime XP, not live goal progress. Defensive de-duplication and saturation
    /// keep malformed imported arrays from trapping or counting the same key twice.
    static func experience(_ events: [RewardEvent]) -> Int {
        var keys: Set<String> = []
        var total = 0
        for event in events where keys.insert(event.key).inserted && event.xp > 0 {
            let sum = total.addingReportingOverflow(event.xp)
            total = sum.overflow ? Int.max : sum.partialValue
        }
        return total
    }

    static func unlockedPetIDs(_ events: [RewardEvent]) -> Set<String> {
        Set(events.compactMap(\.petID).filter { petIDs.contains($0) })
    }
}
