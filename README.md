# GoalPet / 攒攒兽 — SwiftUI MVP 工程骨架

iOS 17+，SwiftUI + Observation + SwiftData + Swift Charts；工程需 **Xcode 16 或更新兼容版本** 打开。无第三方运行依赖，不含服务端实现，客户端不保存 AI API Key。食物识别默认离线 Mock，可注入 HTTPS 后端代理服务。

## 当前交付

- Design System：语义颜色、深浅色、卡片、数字和系统字体、VoiceOver、Dynamic Type。
- 五 Tab：首页、记账、健康、宠物、我的。
- 账单新增/编辑/软删除/恢复、类别/文本筛选、全历史切换、自然月汇总与自定义预算周期。
- 个人攒钱目标创建/编辑/暂停/恢复（原归档入口也用于暂停）、存入/取出流水、删除/恢复与阶段进度重算；仍限制一个活跃个人目标。
- 体重新增/编辑/删除、kg/lb、趋势与按记录日计算的 7 日移动平均、健康目标。
- 可关闭的成年 BMR/TDEE 描述性估算，不生成摄入处方。BMI 为可选显示。
- 三只原创像素宠物图鉴，依据本机追加式奖励账本显示锁定/解锁；累计 20/100/250 XP 解锁 cat/whale/bird。
- 目标与奖励：UTC 每日三项记录任务各 10 XP，个人储蓄四级里程碑各 20 XP；健康趋势里程碑不奖励体重变化，家庭目标不发个人 XP。
- 本地家庭组创建/重命名、成员标签重命名/归档/恢复、共同攒钱目标与按币种分列的成员净贡献。**没有真实登录、邀请、身份验证或跨用户共享**。
- HealthKit 七项指标按需只读显示，权限请求与读取分开；仅内存、不导入记录、不参与奖励、不发给第三方或 Watch。
- watchOS 10+ 只读伴侣：默认关闭、显式开启后发送每日任务/完成状态、累计 XP 和已解锁宠物 ID；不含原始 HealthKit 数据，但任务会透露记录行为。
- 食物照片选择、限量读取、缩图及重新编码；Mock/Remote 识别协议、结构化 JSON 校验、逐项编辑/添加/删除、人工确认后本地保存及饮食历史。
- 远程上传同意与保存确认分离；Mock 结果仅在会话内保留，不进入正式记录、统计或奖励。真实识别需另行接入后端和登录令牌来源。
- 305 个 XCTest 测试方法：47 基线 + 72 饮食 + 50 引擎 + 23 集成 + 37 HealthKit + 63 Watch + 13 家庭。本轮功能扩展新增 186 个；本次仅更新文档，没有新增或执行测试。Preview 使用隔离内存库，不启动 WatchConnectivity 会话。

## 在 Mac 上运行

1. 将整个仓库复制或克隆到 Mac，保留目录结构。
2. 用 Xcode 16+ 打开 [GoalPet.xcodeproj](GoalPet.xcodeproj/project.pbxproj)。不需要重新创建 App、安装包或手动添加 Swift 文件。
3. 选择共享的 **GoalPet** Scheme 和已安装的 iPhone 模拟器，选择 Product → Run。
4. 首次启动账单、目标和体重为空；创建的仅有个人资料和默认账户。宠物初始锁定，符合条件的本地记录自动产生奖励。生产入口使用 `AppRuntimeView` 刷新进度和管理 Watch 生命周期，Preview 不使用该运行时。
5. 真机运行时，为 iPhone **GoalPet** 和 Watch **GoalPetWatch** Target 选择同一 Team，分别设置唯一 Bundle Identifier，并将 Watch 的 `WKCompanionAppBundleIdentifier` 改成 iPhone ID（Debug/Release 均检查）。iPhone HealthKit entitlement 已在 [Config/GoalPet.entitlements](Config/GoalPet.entitlements)，读取用途说明 `NSHealthShareUsageDescription` 已配置；需核对实际签名配置及权限。Watch 为现代单 Target App，无独立 WatchKit Extension。详细步骤见 [docs/GOALS_HEALTH_WATCH.md](docs/GOALS_HEALTH_WATCH.md)。
6. Product → Test（⌘U）运行 XCTest。选择 SwiftUI Canvas 查看 Preview；Preview 只使用内存库。

HealthKit 为 iPhone 可选只读功能；Watch 使用 WatchConnectivity 和配对伴侣配置，不读取 HealthKit。不需要 iCloud、Apple 登录或相机 Capability。食物照片使用系统 PhotosPicker，只接收用户选择的照片，不申请整个图库访问权限，也不启用相机。系统可能需下载用户选择的 iCloud 照片；这不是本应用向识别代理上传。

## 验证状态：请勿混同静态检查与编译

生成环境为 Windows，没有 swift、xcodebuild 或 iOS SDK。**尚未在 Xcode 编译、运行模拟器或执行 XCTest。**

已经提供真实 Xcode 工程和 [macOS CI](.github/workflows/ios.yml)，不是只有零散 Swift 代码。CI 配置在 macOS 上选择 Xcode 16，执行 iPhone 模拟器 build/test，以及 Watch 通用模拟器 Debug 和通用设备 Release 未签名构建（`CODE_SIGNING_ALLOWED=NO`）。这些是配置而非执行结果：本次没有运行或触发 CI，也没有模拟器/真机运行验证；未签名构建不能证明配对、签名或发布就绪。

本地已进行工程引用、Scheme XML、资源 JSON、源代码静态审查和 whitespace 检查。是否完全通过 Apple 编译器，以首次 Xcode/CI 的结果为准。

## 数据流与文件职责

View → AppViewModel → AppRepository → LocalRepository → SwiftData。

食物识别另走 View → FoodRecognitionViewModel → FoodRecognitionService；只有确认后的不可变餐食快照交给 AppViewModel 保存。详细架构、安全边界及后端契约见 [docs/FOOD_RECOGNITION.md](docs/FOOD_RECOGNITION.md)。

本阶段使用共享可观察 ViewModel 保持首页和各模块一致；随着功能增长可按模块拆分。所有 View 都只读快照、调用 ViewModel 方法，不直接读写 ModelContext 或发起网络请求。

文件逐项索引和完整开发机路径见 [docs/FILES.md](docs/FILES.md)。

目标/奖励原子写入、家庭边界、HealthKit 隐私、Watch 协议与签名验收见 [docs/GOALS_HEALTH_WATCH.md](docs/GOALS_HEALTH_WATCH.md)。

## 数据约束

- 金额采用 Int64 最小货币单位。UI 固定人民币；解析器和模型支持 CNY/USD/EUR/GBP/JPY，不提供汇率换算。
- 单笔/账本及目标资金流水设置容量上限，避免 Int64 聚合溢出。
- 预算起始日 1—28；周期为开始日包含、结束日不包含。
- 一个活跃个人攒钱目标；暂停后可另建，恢复时仍检查该限制。家庭目标独立于个人目标限制；健康目标也支持暂停/恢复。
- 攒钱余额来自初始金额 + 有效流水，拒绝负余额；资金记录只是账本，不执行转账。
- 资金表单 UUID 在重试间稳定，重复提交不产生第二笔存入。
- 体重统一存 kg；显示单位切换不修改原值；编辑备注不对原体重重新舍入。
- 7 日平均先聚合同日数据，再对最近七个日历日中的记录日平均；少于三个记录日不显示，不补零。
- 未成年人/年龄未知不启用减重或增重目标。关闭或删除出生日期后将这些目标转为记录模式。
- SwiftData 明确使用 cloudKitDatabase: .none，自动保存关闭；显式保存失败回滚，启动失败不删除旧库。
- 家庭关联通过稳定 UUID 引用，仓储校验目标/成员归属；成员只是本地标签，不是认证用户。
- 每日奖励按 UTC 今日的有效收支、非 Mock 已确认餐食、体重记录各发一次 10 XP，不补发历史日。体重任务只奖励记录行为；健康目标暂停不影响每日记录任务。
- 储蓄 25/50/75/100% 各 20 XP：初始金额只影响进度；奖励要求创建后个人净存入达到**完整目标金额**的对应比例，取出抵减净额，家庭目标不发个人 XP。
- 成年人的体重趋势里程碑按最近七个 UTC 日、至少三个不同记录日计算（日内先平均，仅纳入目标开始后的记录）；不按体重数值、方向或速度发 XP。
- `RewardEvent` 仅追加，XP/宠物不可逆；稳定 UUID、每日/里程碑键及零 XP 来源凭据阻止同一记录移日或删除恢复后重复发奖。单一 MainActor 写入者在同一上下文一次保存业务变更与奖励，失败整体回滚，启动/前台刷新重算。此保证不涵盖改时钟、伪造新 UUID、清库或回退旧备份。

## 模型范围与后续迁移

本阶段实现 **13 个 SwiftData 模型**：原有十个业务模型、`FoodRecord`/`FoodItem` 和新增 `RewardEvent`。照片不写入 SwiftData；餐食删除级联删除其食物条目，但不删除已发奖励。Goal Engine 产生进度与奖励候选，Reward Engine 已接入本机幂等奖励账本；HealthKit 仅内存，Watch 使用独立快照缓存，均不是新增 SwiftData 模型。完整模型名单见 [docs/FILES.md](docs/FILES.md)。

个人/家庭目标使用同一 SavingsGoal 模型和可选 familyGroupID 分域。今后真实共享需独立认证、服务端授权、共享记录与冲突协议，不能把本地成员列表当权限系统。当前唯一约束也不能不经评估直接迁移 CloudKit。

已有磁盘数据库升级仍未验证：包括此前 `FoodRecord`/`FoodItem` 及一对多关系，以及本轮新增 `RewardEvent` 和 `HealthGoal.statusRaw`。字段默认值不等于迁移已验证。发布前需冻结 schema、实现版本化迁移，并用旧库副本测试升级；不得删除旧库来掩盖迁移失败。恢复还须保留 UUID 和完整奖励账本，不能以旧奖励库覆盖新凭据。当前原型不承诺开发版本数据库兼容，不应承载不可替代的生产数据，也不是可发布版本。

## 本地化与辅助功能

中文为源语言，静态 SwiftUI 文案和动态 L10n 入口可接 String Catalog；已提供导航等少量英文示例，**不是完整英文版本**。Xcode build 可提取静态文案；动态分类/错误字符串需在正式国际化时补全 Catalog 和复数/语序测试。

深浅色和大字体 Preview 已提供；实际 VoiceOver、对比度、iPad 布局和 iOS 17 真机验收仍需完成。

## 明确排除

本轮不含：Onboarding、识别后端部署及真实登录、相机拍摄、Widget、云端/跨用户同步、订阅、通知、服务端防作弊奖励、全量数据导出/删除和商店素材。已提供本地奖励、只读 HealthKit 和 Watch 快照同步；远程识别客户端尚未连接真实模型供应商。基础数据导出/删除及发布前验证仍须补齐。

## 手动验收清单

- 新增支出、编辑金额、确认删除、恢复；首页/列表汇总一致；能查看过去月份记录。
- 设置预算起始日，核对自然月与预算周期摘要的区别。
- 建立目标、存入、取出、删除/恢复；不能使余额小于零；重新启动数据仍在。
- 创建/重命名家庭、增加/重命名/归档/恢复成员标签，按币种核对净贡献；归档保留历史，创建者不能归档；共同目标不混入个人列表，也不发个人 XP。
- 记录至少三个不同日期体重，检查日聚合/移动平均；切换 lb 后只改备注，原 kg 不改变。
- 不提供年龄时只能创建记录/维持目标；代谢建议关闭仍能记体重。
- 检查浅色、深色、辅助功能大字体和表单错误保留；无网络时本地功能不受影响。
- 健康 → 饮食与食物识别：查看 Mock、编辑/添加/删除条目、确认后检查历史仍为空；新建手动记录再确认，历史应出现记录并在重启后保留。
- 上传前必须单独勾选同意；改变任一结果、餐别或日期后必须重新勾选保存确认。验证未知营养值不是零，热量范围不会取中点入库。
- 在 Mac 上验证 PhotosPicker 的 JPEG/PNG/HEIC、超大文件、取消及快速切换；代理集成后验证无网络、超时、422 无法识别、重定向拒绝与实际流式响应上限。
- 按 [docs/GOALS_HEALTH_WATCH.md](docs/GOALS_HEALTH_WATCH.md) 验证 UTC 切日、奖励重放/回滚、暂停恢复、HealthKit 权限与清理、Watch 离线清除/本机隐藏/重启屏障及真机配对；这些运行时验收尚未执行。