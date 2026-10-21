import SwiftUI

@MainActor
struct WatchSettingsView: View {
    @ObservedObject var sync: PhoneWatchSync

    var body: some View {
        Form {
            Section("选择同步到配对手表") {
                Toggle("同步今日任务与宠物状态", isOn: Binding(
                    get: { sync.isEnabled }, set: { sync.setEnabled($0) }
                ))
                Text("默认关闭。开启后发送任务名称、完成状态、累计经验与已解锁宠物 ID。任务完成状态可能反映你是否记录体重或饮食，请仅在愿意在配对手表显示时开启。")
                Text("不发送 HealthKit 数值或样本、体重、心率、睡眠、财务金额、照片或家庭成员信息。手表仅查看状态，不能领取或发放奖励。")
            }
            Section("传输状态") {
                Text(statusText)
                Button("重试同步") { sync.start() }
                Text("同步为最终一致而非实时保证；关闭后会排队发送清除通知。离线手表在收到通知前可能仍有旧缓存。手表也支持立即清空本机显示。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apple Watch")
    }

    private var statusText: String {
        switch sync.status {
        case .disabled: return "同步已关闭，清除通知已排队（可用时发送）。"
        case .unsupported: return "此设备不支持 WatchConnectivity。"
        case .activating: return "正在激活连接…"
        case .notPaired: return "尚未配对 Apple Watch。"
        case .watchNotInstalled: return "请先安装手表 App。"
        case .waitingForSnapshot: return "等待新的状态快照。"
        case .queued: return "最新状态已交给系统排队传输，不代表手表已接收。"
        case .retryNeeded: return "暂未发送，回到前台或点击重试。"
        case .invalidSnapshot: return "状态不符合传输格式，未发送。"
        }
    }
}