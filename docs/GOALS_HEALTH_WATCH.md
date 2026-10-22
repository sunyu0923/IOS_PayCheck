# 目标、奖励、HealthKit、Watch 与本地家庭

本文对应当前实现，不是发布或测试通过声明。iPhone 为 iOS 17+，伴侣为 watchOS 10+；需 macOS 与 Xcode 16 或更新兼容版本。没有第三方运行依赖。文件总索引见 [FILES.md](FILES.md)，食物代理边界见 [FOOD_RECOGNITION.md](FOOD_RECOGNITION.md)。

## 目标与奖励规则

实现入口：[GoalPet/Core/Goals/GoalEngine.swift](../GoalPet/Core/Goals/GoalEngine.swift)、[GoalPet/Core/Goals/RewardEngine.swift](../GoalPet/Core/Goals/RewardEngine.swift)、[GoalPet/Models/RewardModels.swift](../GoalPet/Models/RewardModels.swift)。UI 只展示引擎结果，不另行推断奖励资格。

### UTC 每日三项任务

按 Gregorian **UTC 00:00 到次日 00:00** 分桶，只评估今日且不晚于当前时间的有效记录；不随设备时区变化，不补发历史日奖励。每种任务每天一次 **10 XP**（合计最多 30 XP/UTC 日）：

| 任务 | 完成依据 |
|---|---|
| 记录一笔收支 | 未删除、有效金额/币种/类型的账单 |
| 记录一餐 | 已确认、非空的 Manual/Remote 餐食；Mock 不入库也不发奖 |
| 记录一次体重 | 有效的应用内体重记录，只奖励记录行为，不奖励数值、增减方向或速度；不以成年为此任务的前提 |

当前完成状态与累计获奖不同：删除记录可使任务变为未完成，但已发 XP 不撤销；恢复、重复刷新或将同一获奖记录改到另一日不能再次发奖。HealthKit 读取结果不属于这些来源。

### 储蓄里程碑

- 每个目标展示 **25/50/75/100%** 四阶段。当前余额为初始金额加有效存入减取出，初始金额可推动显示进度。
- 只有活跃的**个人**目标可获各阶段 **20 XP**。除当前余额达到阈值外，目标创建后的个人净存入也须达到**完整目标金额 × 阶段比例**；不能按“目标减初始金额”计算。
- 初始金额不奖励；取出抵减净存入；已删除或未来流水不参与评估。流水没有单独的创建时间字段，使用有效记录日期 `date >= goal.createdAt` 判断创建后资格，不能声称这是服务器审计时间。
- 例如目标 1,000、初始 800：虽显示达到 75%，仍无里程碑 XP；创建后净存入 250 才可获得 25% 的 20 XP。
- 家庭目标可展示阶段，但**不发个人 XP**。修改目标仍保留目标 UUID，同一阶段不会因重命名、修改金额、暂停/恢复而再次发奖。

### 健康趋势里程碑与暂停

- 仅在年龄已确认为成年人且减重/增重方向及目标有效时展示 25/50/75/100% 趋势；记录/维持模式没有此类趋势阶段。目标体重需在有效范围，已知身高时拒绝低 BMI 减重目标；不提供医疗建议。
- 使用**最近七个 UTC 日（今日及前六日）**、目标开始后且不晚于当前时刻的有效体重；同一 UTC 日先求平均，再对有记录的日均值平均。至少 **3 个不同 UTC 记录日**才计算进度，不补零，不用同日多条凑足天数。
- 体重里程碑**永不产生 XP/宠物奖励**；每日体重“记录”任务仍可获 10 XP。不要将健康页采用其图表日历的移动平均与此 UTC 引擎窗口混同。
- 储蓄和健康目标均可暂停/恢复；暂停保留历史与当前阶段显示，标注已暂停。暂停储蓄目标不产生新里程碑奖励，不能新增资金记录；编辑须先恢复。健康目标暂停不阻止每日记录任务。
- 沿用**最多一个活跃个人储蓄目标**政策：暂停后可另建，恢复旧目标时须先暂停其他活跃个人目标；家庭目标不占此名额。原储蓄“归档”入口也转为暂停。

## 追加式账本、原子性与生命周期

[GoalPet/App/AppViewModel.swift](../GoalPet/App/AppViewModel.swift) 的所有业务写入经 `write` → [GoalPet/Core/LocalRepository.swift](../GoalPet/Core/LocalRepository.swift) 的 `commit`：

1. 同一 `ModelContext` 中修改业务记录，读取包含待保存变更的快照。
2. `GoalEngine.evaluate` 产生候选，`RewardEngine.reconcile` 追加奖励、来源凭据及解锁事件。
3. 重新读取返回快照，**只保存一次**；任一步失败都回滚同一上下文，不能先保存业务再另存奖励。自动保存关闭。

`RewardEvent` 按唯一 `key` 仅追加，包含正 XP 事件、零 XP 的 `source:<kind>:<UUID>` 来源凭据和 `pet:<ID>` 解锁事件。每日键包含任务类型与 UTC 日期，里程碑键包含稳定目标 UUID 与阶段。奖励来源/目标 UUID 必须在重试、编辑和恢复间稳定；零 XP 凭据也不能删除。奖励页隐藏内部来源凭据，但保留最近 20 条 XP/宠物事件。

累计 XP 是终身本地账本总额，不是当前进度。**已得 XP 和宠物不可逆**，不会因删除餐食/体重/账单、删除资金记录、取出资金或编辑/暂停目标扣回。累计 20/100/250 XP 分别解锁 `cat`/`whale`/`bird`；解锁事件本身为零 XP。

`AppViewModel` 初始化时若存在奖励候选或已有奖励，会进行刷新；即使没有新候选，奖励对账也可修复缺失的解锁行。生产 [GoalPet/App/AppRuntimeView.swift](../GoalPet/App/AppRuntimeView.swift) 在启动、回到前台及前台 UTC 切日刷新；前台每分钟检查日期并发布最新状态，失败显示可重试提示。它持有单一 `PhoneWatchSync`。这不是后台任务，也不补发历史日奖励。

此保证要求**单 MainActor 写入者/上下文**；唯一键不是多上下文、云端并发或防作弊协议。时钟篡改、新造 UUID、清库、奖励账本回退不在保证范围。备份恢复须保留 UUID 并合并/保留完整奖励账本，不能以旧凭据覆盖新凭据。

[GoalPet/Resources/PreviewHost.swift](../GoalPet/Resources/PreviewHost.swift) 使用独立内存库与示例，可能在内存中产生示例奖励，但不写生产库；Preview 不经过 `AppRuntimeView`，不启动 WatchConnectivity 会话。

## 本地家庭管理（选择的交付范围）

实现见 [GoalPet/App/AppViewModel+Family.swift](../GoalPet/App/AppViewModel+Family.swift) 和 [GoalPet/Features/Family/FamilyView.swift](../GoalPet/Features/Family/FamilyView.swift)。范围是**一个本地家庭组**，不是实际家庭账号或共享服务。

- 创建/重命名家庭，新增/重命名成员标签，归档/恢复成员；名字去首尾空白后 1—60 字，同家庭成员重名校验不区分大小写和音调符号，包含已归档标签。
- 创建者 `owner` 不能归档，只是本地数据约束而非权限控制。归档不删成员 UUID、历史流水或余额，但不能再选作新贡献者；恢复时检查名称冲突。
- 贡献按**目标币种分别**计算有效存入减取出，包含归档目标/成员历史，不包含初始金额、已删除、个人、其他家庭或孤立流水。不同币种不相加、不兑换。
- 目标归属不能随意更改，新增家庭流水必须选择该家庭的活跃成员。家庭阶段不奖励个人 XP。
- 没有登录、真实邀请、身份验证、授权、通知、真实转账或跨设备/跨用户共享；角色不代表账号权限。个人账本、健康和饮食记录不会分享到家庭。

## HealthKit：七项只读、内存隔离

实现见 [GoalPet/Core/Health/HealthKitService.swift](../GoalPet/Core/Health/HealthKitService.swift) 与 [GoalPet/Features/Health/HealthKitView.swift](../GoalPet/Features/Health/HealthKitView.swift)。只访问系统 HealthKit，不接入第三方健康 API；HealthKit 内记录仍可能来自第三方 App，页面如实显示来源。

| 指标 | 读取与显示方式 |
|---|---|
| 步数、活动能量、锻炼分钟 | 本地日历今日起点至现在，`HKStatisticsQuery` 的 `cumulativeSum` 合并统计 |
| 心率、静息心率、体重 | 不晚于当前时刻的最近一次样本，显示样本时间；不是强称“今日” |
| 睡眠 | 最近 24 小时的 asleep unspecified/core/deep/REM 区间，裁剪到窗口并跨来源/阶段求区间并集；不计 in-bed/awake，不叠加重叠时段 |

- 初始不选指标，构造或打开页面**不请求权限、不自动读取**；“请求所选类型的读取权限”与“刷新所选数据”是两个独立显式动作。`toShare` 为空，不写健康数据。
- **请求流程完成不表示读取获准**。HealthKit 出于隐私不透露读取拒绝，不能用写权限状态判断读取权限；无数据、不可用、未允许读取不可被可靠区分。缺失/未知结果保持可缺省或“不可用/暂无数据”状态，**不补为 0**；真实读取的零值才可显示零。
- 来源详情包含名称、bundle ID、可用版本及设备名称/厂商/型号/硬件/固件/软件版本；不暴露设备标识符、原始 metadata 或原始错误。数量样本保留原 HealthKit UUID 用于去重，来源/设备详情可能缺省。
- 累计总量使用合并统计，另查 `separateBySource` 及匹配样本仅为来源说明；**绝不把各来源样本简单相加**，也不能推断每台设备对总量的分配。不承诺与 Apple 健康 App 显示完全相等，查询窗口、可读数据及系统展示口径可能不同。
- 历史/来源查询上限 10,000 条，达到上限保守拒绝显示不完整结果；最近一次查询只取一条。取消会停止仍在执行的查询，忽略过期回调；系统授权弹窗本身没有可调用的关闭 API。
- 结果仅保存在当前页面内存；切换选择、重置、离开页面或进入后台均取消并清空结果。不会因授权弹窗导致的 `.inactive` 立即清空；重置不撤销系统权限，撤销需系统健康设置。
- **不写 SwiftData、不自动导入应用体重、不参与目标或奖励，不发往食物代理、第三方网络、家庭或 Watch**。系统健康自身同步由系统管理。未授权/读取失败不影响其他功能，清理内存不是安全擦除承诺。

## Watch：只读最新状态与隐私屏障

### 工程与允许的载荷

[GoalPet.xcodeproj/project.pbxproj](../GoalPet.xcodeproj/project.pbxproj) 定义现代 **单 Watch App Target** `GoalPetWatch`，最低 watchOS 10，无单独旧式 WatchKit Extension。iPhone 嵌入伴侣；Watch 不能独立于 iPhone 使用。Foundation-only [Shared/WatchSnapshot.swift](../Shared/WatchSnapshot.swift) 同时编入两端。

iPhone 的分享偏好默认关闭，需在 Watch 设置中显式 opt-in。生产运行时只映射 GoalEngine 的应用自有任务 ID/标题/完成状态、累计 XP、已解锁宠物 ID，外加版本/会话/排序/时间/清除元数据。不发送原始 HealthKit 样本/数值、应用体重、心率、睡眠、金额、食物内容、照片、资料或家庭成员数据；**任务标题及完成状态仍可能透露记体重、饮食或收支的行为**，不能称其没有隐私信息。

### 严格契约与顺序

- 传输键为 `goalpet.snapshot`，值为 JSON `Data`；接收的 application context 只能有此一个键。版本为 1，顶层和任务字段须精确匹配，拒绝未知/缺失字段及不合类型、重复 ID 或越界值。
- 编解码入口限制 **32 KiB**；最多 32 项任务、64 个宠物 ID、1,000,000,000 XP。ID 最多 96 ASCII 字节且字符受限，任务标题非空、最多 160 UTF-8 字节且不含控制字符。生产当前只有三项每日任务；协议容量不是新增任务承诺。
- `revision` 为 **Int64**，范围 1…9,007,199,254,740,991。同一会话 UUID 下 epoch 固定且 revision 必须严格递增；不同 UUID 必须有严格更新的 `sessionStartedAt` 逻辑 epoch。
- `sessionStartedAt` 虽用日期值编码，却是排序 epoch，不是新鲜度时间。发布者持久化高水位，重启/同意状态变化建立新会话；新 epoch 至少越过旧高水位，时钟回拨不使旧会话重新有效。高水位损坏/耗尽时拒绝发送，不重置绕过。
- `generatedAt` 才是生成时的**墙上时钟**时间，不用于排序。时间戳须有限且在 0…4,102,444,800 秒范围；正常新载荷未来超过 300 秒拒收。跨 UTC 日、超过 24 小时或未来偏差过大标记陈旧；陈旧不是自动重新同步或自动清空。
- 清除 tombstone 必须无任务、零 XP、无宠物，保留排序元数据。重复/过时消息被忽略，不更新接收时间；清除通知即使两端时钟不一致也可清理显示。

### 排队、缓存与本机隐藏

[GoalPet/Core/Watch/PhoneWatchSync.swift](../GoalPet/Core/Watch/PhoneWatchSync.swift) 使用 `updateApplicationContext`，只保留最新状态，不用 `isReachable` 阻塞排队。**queued 仅表示交给系统，不表示 Watch 已收到**；连接、配对/安装状态和生命周期决定后续重试，为最终一致而非实时保证。没有 `sendMessage` 领取/修改命令通道；Watch 不能发 XP、领取奖励或编辑业务。

关闭 iPhone 分享立即替换待发载荷并排队 tombstone；离线 Watch 收到之前可能仍显示旧缓存，不能承诺远程即时擦除。Watch 的 [GoalPetWatch/WatchSnapshotStore.swift](../GoalPetWatch/WatchSnapshotStore.swift) 仅把经过校验/净化的状态保存至 UserDefaults；无效新包不覆盖有效缓存或清除屏障。

Watch 上 **Clear and hide on Watch** 可离线立即清除本 App 显示载荷，持久化本机阻断偏好及 tombstone 排序屏障；后续包仅推进屏障，不保存显示内容。iPhone 再次开启不能解除这个选择，重启 Watch 也保持隐藏。只有 Watch 显式 **Show new iPhone updates** 才解除；解除前先消化当前 context 作为屏障，不复显旧包，须等待更高序的新 iPhone 更新。缓存恢复不伪造新接收时间；时钟回拨导致缓存载荷过度超前时，丢弃显示内容但保留屏障。

## macOS 构建与签名步骤

1. 用 Mac 的 Xcode 16+ 打开 [GoalPet.xcodeproj/project.pbxproj](../GoalPet.xcodeproj/project.pbxproj) 对应工程，安装 iOS/watchOS SDK 和所需模拟器；Windows 无法编译此项目。
2. 在 **GoalPet** 与 **GoalPetWatch** 的 Signing & Capabilities 中选择同一开发 Team，设置自己的唯一 iPhone/Watch Bundle ID（例如 iPhone ID 加 `.watchkitapp` 作为 Watch ID），确保 Debug/Release 一致配置；测试 Target 也使用适当的唯一测试 ID/Team。
3. Watch 的 `WKCompanionAppBundleIdentifier` 必须精确等于 iPhone Bundle ID。现有 `WKApplication=YES`、`WKRunsIndependentlyOfCompanionApp=NO`、`WKWatchOnly=NO` 与 iPhone 的 Embed Watch Content 已配置；不要额外创建旧式 Extension。
4. iPhone 的 `CODE_SIGN_ENTITLEMENTS` 指向 [Config/GoalPet.entitlements](../Config/GoalPet.entitlements)，包含 `com.apple.developer.healthkit`；在 Team/App ID/provisioning 中核对 HealthKit 能力。生成 Info.plist 的 `NSHealthShareUsageDescription` 已在工程 Debug/Release 设置，用途为本机只读展示七项指标；按实际发布文案核对。不请求写权限，也不启用 HealthKit 后台交付；Watch 不需要 HealthKit entitlement。
5. 选择共享 **GoalPet** Scheme 与 iPhone 模拟器运行/测试；选择 **GoalPetWatch** Scheme 构建/运行伴侣。另用实际配对 iPhone/Watch 验证签名、安装、只读授权、离线/重连及隐私行为，不能只依赖模拟器。

[.github/workflows/ios.yml](../.github/workflows/ios.yml) 配置 macOS 15 + 已安装 Xcode 16：iPhone 模拟器 Debug build/test；Watch 通用模拟器 Debug build 与通用 watchOS 设备 Release build，均禁用签名。**工作流未在本次执行或触发**；设备构建是未签名编译检查，不是安装、配对运行、分发归档或商店发布验证。没有独立 Watch 运行时测试 Target。

## 模型、迁移与验证状态

现有 **13 个 SwiftData 模型**（完整名单见 [FILES.md](FILES.md)）。HealthKit 内存结果和 Watch UserDefaults 快照不是新增持久实体。**新增 `RewardEvent`、`HealthGoal.statusRaw`，以及此前 `FoodRecord`/`FoodItem` 关系的旧磁盘库迁移均未验证**；默认 `statusRaw = "active"` 不是迁移成功证据。需冻结 schema、提供版本化迁移策略、用旧库副本测试升级/失败恢复且保留奖励凭据；启动失败不得删库兜底。

源码共有 **305 个 XCTest 方法**：

| 范围 | 数量 |
|---|---:|
| 基线 | 47 |
| 饮食（56 本地 + 16 远程客户端） | 72 |
| Goal/Reward 引擎 | 50 |
| 业务/奖励集成 | 23 |
| HealthKit | 37 |
| Watch 契约/排序/缓存 | 63 |
| 本地家庭管理 | 13 |
| 合计 | 305 |

相对原 119 个，本轮功能扩展新增 **186 个**。**未执行 Xcode 编译、XCTest、模拟器、真机或任何运行时测试，也未运行 CI；不是发布就绪。** HealthKit 测试使用离线样本/注入来源和服务（未保存样本没有实际 `sourceRevision`，不能靠写入真实健康库填充）；Watch 测试验证纯契约/状态和隔离偏好，不证明真实 WCSession 交付。

### 必须补做的运行时验收（未执行）

- 在 Mac 执行两端构建和全部 XCTest；验证持久库重启/旧库升级、保存失败整体回滚、启动修复解锁、重复刷新不重复发奖。
- 跨 UTC 午夜和设备时区测试三项任务，修改获奖记录日期、删除/恢复、重复提交；验证初始储蓄不发奖、净存入完整目标阈值、取出及暂停/恢复单活跃限制。
- 验证成年资格变化、七 UTC 日至少三天、同日重复及目标开始日过滤；体重里程碑永不发 XP，健康目标暂停不影响每日记录。
- 验证家庭重名（含归档/大小写/音调）、创建者不可归档、归档成员不可新增贡献、恢复历史及分币种统计；不产生真实邀请或共享。
- 真机分别验证 HealthKit 可用/无数据/部分可读/请求失败、请求后不自动读取；核对统计来源与睡眠重叠、导航离页/后台清理及过期回调不复活数据；不把读不到记录标成“拒绝”或零。
- 配对真机验证默认关闭、显式开启、无配对/未安装、离线最新状态/关闭 tombstone、切换配对手表、损坏/重复/过时包、时钟回拨及陈旧提示。
- Watch 离线清空隐藏后重启，再从 iPhone 开关分享，确认仍隐藏；Watch 明确重新启用后只显示新序快照，无领取或修改入口。
- 验证两端 VoiceOver、Dynamic Type、深浅色、隐私提示，以及签名/entitlement/用途文案与真实能力一致。正式发布还需独立隐私、导出/删除、迁移和商店资料验收。