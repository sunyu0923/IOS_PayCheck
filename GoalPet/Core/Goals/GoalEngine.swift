// iOS 17 / Swift 5. Read-only domain evaluation; no SwiftUI or persistence writes.
import Foundation

@MainActor enum GoalEngine {
    private static let stages = [25, 50, 75, 100]

    /// Daily display AND award dates use Gregorian UTC, explicitly labelled in task
    /// titles. The supplied calendar is used only for adult age eligibility; changing
    /// the device calendar/time zone cannot produce an extra daily reward bucket.
    /// Only today's records earn daily XP; startup does not backfill historical days.
    static func evaluate(_ data: AppSnapshot, now: Date,
                         calendar: Calendar = .current) -> GoalEvaluation {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = utc.startOfDay(for: now)
        let components = utc.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", components.year ?? 0,
                         components.month ?? 0, components.day ?? 0)
        let earned = Set(data.rewards.map(\.key))
        var tasks: [DailyTaskProgress] = []
        var milestones: [GoalMilestoneProgress] = []
        var candidates: [RewardCandidate] = []

        func isToday(_ date: Date) -> Bool { date >= today && date <= now }
        func daily(_ kind: String, title: String, records: [UUID]) {
            let key = "daily:\(kind):\(day)"
            tasks.append(DailyTaskProgress(id: key, title: title, isComplete: !records.isEmpty))
            guard !earned.contains(key) else { return }
            // Sorting keeps selection deterministic regardless of fetch order.
            let sources = Set(records.map { "source:\(kind):\($0.uuidString.lowercased())" }).sorted()
            guard let source = sources.first(where: { !earned.contains($0) }) else { return }
            candidates.append(RewardCandidate(key: key, title: title, xp: 10, sourceKey: source))
        }

        daily("finance", title: "记录一笔收支（UTC 今日）", records: data.transactions.filter {
            $0.deletedAt == nil && $0.amountMinor > 0 && $0.amountMinor <= Money.maximum &&
                TransactionKind(rawValue: $0.kindRaw) != nil &&
                Money.currencies.contains($0.currency) && isToday($0.date)
        }.map(\.id))
        daily("meal", title: "记录一餐（非演示，UTC 今日）", records: data.meals.filter {
            ($0.sourceRaw == FoodRecognitionMode.manual.rawValue ||
             $0.sourceRaw == FoodRecognitionMode.remote.rawValue) &&
                !$0.items.isEmpty && $0.confirmedAt <= now && isToday($0.recordDate)
        }.map(\.id))
        // Reward the act of recording only, never the number/direction/speed of change.
        // This matches the repository's accepted measurement range, including minors.
        daily("weight", title: "记录一次体重（UTC 今日）", records: data.weights.filter {
            $0.kilograms.isFinite && (10...500).contains($0.kilograms) && isToday($0.date)
        }.map(\.id))

        for goal in data.goals.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let contributions = data.contributions.filter {
                $0.goalID == goal.id && $0.deletedAt == nil && $0.date <= now
            }
            // Decimal avoids Int64 overflow and preserves exact threshold comparisons.
            let balance = Decimal(goal.initialMinor) + contributions.reduce(Decimal(0)) {
                $0 + Decimal($1.signedMinor)
            }
            let netNew = contributions.filter {
                $0.date >= goal.createdAt && $0.memberID == nil
            }.reduce(Decimal(0)) { $0 + Decimal($1.signedMinor) }
            let paused = goal.statusRaw != "active"
            for stage in stages {
                let threshold = Decimal(goal.targetMinor) * Decimal(stage) / 100
                let reached = goal.targetMinor > 0 && goal.createdAt <= now && balance >= threshold
                let milestone = GoalMilestoneProgress(goalID: goal.id, title: goal.name,
                    percentage: stage, isReached: reached, isPaused: paused)
                milestones.append(milestone)
                // Seed affects displayed progress, NEVER reward eligibility. A 25% award
                // requires net post-creation personal deposits >=25% of the FULL target,
                // not 25% of (target - seed). Withdrawals reduce this net. Since existing
                // contributions have no createdAt, their effective date is the only
                // available post-creation gate. Family milestones NEVER award personal XP.
                if reached && !paused && goal.familyGroupID == nil && netNew > 0 && netNew >= threshold &&
                    !earned.contains(milestone.id) {
                    candidates.append(RewardCandidate(key: milestone.id,
                        title: "\(goal.name) · \(stage)%", xp: 20))
                }
            }
        }

        // No health milestone candidates, even for adults: weight amount/speed is not
        // incentivized. UUID-based stage IDs remain unchanged after editing a goal.
        let adult = data.profiles.first?.dateOfBirth.flatMap {
            calendar.dateComponents([.year], from: $0, to: now).year
        }.map { $0 >= 18 } ?? false
        if adult {
            for goal in data.healthGoals.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                guard let target = goal.targetKG, goal.startKG.isFinite, target.isFinite,
                      (30...350).contains(goal.startKG), (30...350).contains(target),
                      goal.startDate <= now,
                      (goal.kindRaw == "lose" && target < goal.startKG) ||
                        (goal.kindRaw == "gain" && target > goal.startKG) else { continue }
                if goal.kindRaw == "lose", let height = data.profiles.first?.heightCM,
                   let bmi = HealthMath.bmi(kg: target, heightCM: height), bmi < 18.5 { continue }
                let lower = utc.date(byAdding: .day, value: -6, to: today) ?? today
                let points = data.weights.filter {
                    $0.date >= goal.startDate && $0.date >= lower && $0.date <= now &&
                        $0.kilograms.isFinite && (30...350).contains($0.kilograms)
                }.map { WeightPoint(date: $0.date, kg: $0.kilograms) }
                // Average within each UTC day first: duplicates cannot supply the three
                // distinct days or overweight one day's contribution to the rolling mean.
                let days = HealthMath.daily(points, calendar: utc)
                let progress: Double
                if days.count >= 3 {
                    let average = days.map(\.kg).reduce(0, +) / Double(days.count)
                    progress = GoalMath.weight(start: goal.startKG, target: target, current: average) ?? 0
                } else { progress = 0 }
                for stage in stages {
                    milestones.append(GoalMilestoneProgress(goalID: goal.id,
                        title: goal.kindRaw == "lose" ? "体重趋势（不发放里程碑奖励）" : "增重趋势（不发放里程碑奖励）",
                        percentage: stage, isReached: progress >= Double(stage) / 100,
                        isPaused: goal.statusRaw != "active"))
                }
            }
        }
        return GoalEvaluation(tasks: tasks, milestones: milestones, candidates: candidates)
    }
}
