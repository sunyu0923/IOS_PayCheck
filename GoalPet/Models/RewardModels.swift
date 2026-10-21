// iOS 17 / Swift 5. Reward values and the append-only, local lifetime award ledger.
import Foundation
import SwiftData

struct DailyTaskProgress: Identifiable, Equatable {
    let id: String
    let title: String
    let isComplete: Bool
}

struct GoalMilestoneProgress: Identifiable, Equatable {
    let goalID: UUID
    let title: String
    /// The stage threshold (25, 50, 75, or 100), not a rounded live balance.
    let percentage: Int
    let isReached: Bool
    let isPaused: Bool

    // Health goal edits must retain their UUID. Never include updatedAt/startDate revisions.
    var id: String { "goal:\(goalID.uuidString.lowercased()):\(percentage)" }
}

struct RewardCandidate: Equatable {
    let key: String
    let title: String
    let xp: Int
    let petID: String?
    /// Optional lifetime recording receipt. Prevents moving the same record to a new
    /// UTC date to earn another daily award. Not an additional persisted model field.
    let sourceKey: String?

    init(key: String, title: String, xp: Int, petID: String? = nil, sourceKey: String? = nil) {
        self.key = key
        self.title = title
        self.xp = xp
        self.petID = petID
        self.sourceKey = sourceKey
    }
}

struct GoalEvaluation: Equatable {
    let tasks: [DailyTaskProgress]
    let milestones: [GoalMilestoneProgress]
    let candidates: [RewardCandidate]
}

/// Append-only by repository contract: never edit/delete these rows, including the
/// zero-XP source receipts and pet unlocks. Deleting/editing a source or goal only
/// changes current progress; awarded XP and pets are deliberately irreversible.
/// Restores must preserve UUIDs AND merge/preserve this ledger, not replace it with
/// an older backup. Clearing the database, changing the clock, or inventing new UUIDs
/// is outside this local-only engine's anti-replay guarantee (no trusted server).
@Model final class RewardEvent {
    @Attribute(.unique) var key: String
    var title: String
    var xp: Int
    var petID: String?
    var earnedAt: Date

    init(key: String, title: String, xp: Int, petID: String? = nil, earnedAt: Date) {
        self.key = key
        self.title = title
        self.xp = xp
        self.petID = petID
        self.earnedAt = earnedAt
    }
}
