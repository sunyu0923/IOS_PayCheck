// iOS 17 / Swift 5. Presentation of engine results and the append-only reward ledger.
// Eligibility, XP totals, and all mutations remain in AppViewModel and the engines.
import SwiftUI

@MainActor
struct GoalProgressView: View {
    let model: AppViewModel
    @State private var errorMessage: String?

    private var recentRewards: [RewardEvent] {
        // Hide internal zero-XP recording receipts, but retain pet unlock events.
        Array(model.data.rewards.filter { $0.xp > 0 || $0.petID != nil }
            .sorted {
                if $0.earnedAt == $1.earnedAt { return $0.key < $1.key }
                return $0.earnedAt > $1.earnedAt
            }.prefix(20))
    }

    var body: some View {
        let evaluation = model.evaluation
        List {
            if let errorMessage {
                Section { InlineError(message: errorMessage) }
            }

            Section {
                LabeledContent("累计经验") {
                    Text("\(model.experience) XP")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(DS.reward)
                }
            } footer: {
                Text("XP 是本机累计奖励，不是当前目标进度。已获得的 XP 和宠物不会因删除记录、取出资金、编辑或暂停目标而撤销。")
            }

            Section {
                ForEach(evaluation.tasks) { task in
                    VStack(alignment: .leading, spacing: DS.small) {
                        Label {
                            Text(verbatim: L10n.text(task.title))
                        } icon: {
                            Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(DS.accent)
                                .accessibilityHidden(true)
                        }
                        Text(task.isComplete ? L10n.text("当前已完成") : L10n.text("当前未完成"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("每日记录 · UTC")
            } footer: {
                Text("每日任务按 UTC 00:00 至次日 00:00 划分，不随设备时区变化；只评估 UTC 今日，不补发历史日期的每日奖励。删除记录后完成状态会重新计算，已发奖励不撤销，也不会因恢复同一记录而重复发放。体重任务只鼓励记录，不奖励体重数值、增减方向或变化速度。")
            }

            Section {
                if let goal = model.healthGoal {
                    LabeledContent("目标状态", value: goal.statusRaw == "active"
                                   ? L10n.text("进行中") : L10n.text("已暂停"))
                    Button(goal.statusRaw == "active" ? L10n.text("暂停健康目标") : L10n.text("恢复健康目标")) {
                        perform { try model.setHealthGoalPaused(goal.statusRaw == "active") }
                    }
                } else {
                    Text("尚未设置健康目标，可前往健康页面设置。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("健康目标")
            } footer: {
                Text("健康里程碑仅展示趋势，不发放 XP 或宠物奖励。暂停健康目标不影响每日记录任务；体重变化本身不获得奖励。")
            }

            Section {
                if evaluation.milestones.isEmpty {
                    Text("暂无可展示的里程碑。记录或维持模式可能没有健康趋势里程碑。")
                        .foregroundStyle(.secondary)
                }
                ForEach(evaluation.milestones) { milestone in
                    GoalMilestoneStatusView(milestone: milestone)
                }
            } header: {
                Text("当前里程碑")
            } footer: {
                Text("这里展示引擎重新计算的当前进度，不是获奖记录。初始储蓄计入进度，但奖励依据创建计划后的个人净存入；家庭目标不发放个人 XP。删除记录或取出资金可能让里程碑回到未达到，已获得的奖励仍保留。")
            }

            Section {
                if recentRewards.isEmpty {
                    Text("尚无奖励记录。完成符合条件的记录后，奖励会自动保存，无需领取。")
                        .foregroundStyle(.secondary)
                }
                ForEach(recentRewards, id: \.key) { reward in
                    VStack(alignment: .leading, spacing: DS.small) {
                        Text(verbatim: rewardTitle(reward)).font(.headline)
                        if reward.xp > 0 {
                            Text("+\(reward.xp) XP")
                                .monospacedDigit()
                                .foregroundStyle(DS.reward)
                        }
                        Text(reward.earnedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("最近奖励")
            } footer: {
                Text("展示最近 20 条经验或宠物奖励，隐藏内部零 XP 记录凭据。发放时间按设备本地时区显示；每日任务边界仍为 UTC。奖励仅保存在本机。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background)
        .tint(DS.accent)
        .navigationTitle(Text("目标与奖励"))
        .refreshable { perform { try model.refreshProgress() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    perform { try model.refreshProgress() }
                } label: {
                    Label("刷新进度", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func rewardTitle(_ reward: RewardEvent) -> String {
        if let pet = PetCatalog.all.first(where: { $0.id == reward.petID }) {
            return L10n.text("已解锁") + " · " + pet.name
        }
        return L10n.text(reward.title)
    }

    private func perform(_ action: () throws -> Void) {
        errorMessage = nil
        do { try action() }
        catch { errorMessage = L10n.text(error.localizedDescription) }
    }
}

/// Shared rendering of engine booleans; never infers thresholds or award eligibility.
struct GoalMilestoneStatusView: View {
    let milestone: GoalMilestoneProgress
    var showsTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.small) {
            if showsTitle {
                Text(verbatim: milestone.title).font(.headline)
            }
            Label {
                Text("\(milestone.percentage)%")
                    .monospacedDigit()
            } icon: {
                Image(systemName: milestone.isReached ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(DS.finance)
                    .accessibilityHidden(true)
            }
            Text(milestone.isReached ? L10n.text("当前已达到") : L10n.text("当前未达到"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if milestone.isPaused {
                Label("目标已暂停", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}