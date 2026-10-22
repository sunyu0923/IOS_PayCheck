# 文件交付清单

下面列出全部交付文件及职责；完整路径由开发机根目录加所列的完整仓库相对路径组成。部分既有 Swift 文件头保留生成路径，新增文件使用职责注释；迁移到 Mac 不需要保留 Windows 路径，源码注释路径不参与构建。

开发机根目录：C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/

| 文件 | 用途 | 依赖 |
|---|---|---|
| [GoalPet/Core/DesignSystem.swift](../GoalPet/Core/DesignSystem.swift) | DS 语义色、卡片、错误提示、主题、本地化入口 | SwiftUI、UIKit |
| [GoalPet/Models/Models.swift](../GoalPet/Models/Models.swift) | 十个本地 SwiftData 模型和 String 枚举 | SwiftData、L10n |
| [GoalPet/Models/RewardModels.swift](../GoalPet/Models/RewardModels.swift) | RewardEvent 追加式奖励实体、每日任务/里程碑/奖励候选值 | Foundation、SwiftData |
| [GoalPet/Core/Goals/GoalEngine.swift](../GoalPet/Core/Goals/GoalEngine.swift) | UTC 每日任务、储蓄/成年体重趋势里程碑与奖励候选 | AppSnapshot、Calculations、领域枚举 |
| [GoalPet/Core/Goals/RewardEngine.swift](../GoalPet/Core/Goals/RewardEngine.swift) | 幂等追加、来源凭据、累计 XP 与宠物解锁，不自行保存 | RewardModels、SwiftData |
| [GoalPet/Core/Calculations.swift](../GoalPet/Core/Calculations.swift) | 金额、日期周期、进度、BMR/TDEE/BMI、移动平均 | Foundation、领域枚举 |
| [GoalPet/Core/LocalRepository.swift](../GoalPet/Core/LocalRepository.swift) | 本地容器、快照、提交与回滚 | 全部 Models |
| [GoalPet/App/AppViewModel.swift](../GoalPet/App/AppViewModel.swift) | 输入校验、跨页面状态、业务与奖励原子写入、启动刷新、暂停恢复 | Repository、Calculations、GoalEngine、RewardEngine |
| [GoalPet/App/AppViewModel+Family.swift](../GoalPet/App/AppViewModel+Family.swift) | 家庭/成员重命名、归档恢复、重名校验、按币种净贡献 | AppViewModel、家庭与储蓄模型 |
| [GoalPet/Resources/PetCatalog.swift](../GoalPet/Resources/PetCatalog.swift) | 三只静态物种定义和像素绘制；解锁来自奖励账本 | SwiftUI、DS |
| [GoalPet/Features/Pets/PetCollectionView.swift](../GoalPet/Features/Pets/PetCollectionView.swift) | 图鉴、奖励驱动的锁定/解锁状态与详情 | AppViewModel、PetCatalog、DS |
| [GoalPet/Features/Finance/FinanceView.swift](../GoalPet/Features/Finance/FinanceView.swift) | 账单列表/编辑/恢复、预算 | AppViewModel、SavingsGoalView、DS |
| [GoalPet/Features/Savings/SavingsGoalView.swift](../GoalPet/Features/Savings/SavingsGoalView.swift) | 个人/家庭目标列表、详情、编辑、资金记录 | AppViewModel、Calculations、DS |
| [GoalPet/Features/Health/HealthDashboardView.swift](../GoalPet/Features/Health/HealthDashboardView.swift) | 健康首页、图表、体重/资料/目标表单 | AppViewModel、Charts、DS |
| [GoalPet/Features/Family/FamilyView.swift](../GoalPet/Features/Family/FamilyView.swift) | 本地家庭重命名、成员重命名/归档/恢复、分币种贡献与共同目标入口 | AppViewModel、SavingsGoalView、DS |
| [GoalPet/Features/Goals/GoalProgressView.swift](../GoalPet/Features/Goals/GoalProgressView.swift) | UTC 任务、里程碑、健康目标暂停恢复、最近奖励 | AppViewModel、RewardModels、PetCatalog、DS |
| [GoalPet/Core/Health/HealthKitService.swift](../GoalPet/Core/Health/HealthKitService.swift) | 七指标只读服务、来源、统计/睡眠归一化与可取消查询 | Foundation、HealthKit |
| [GoalPet/Features/Health/HealthKitView.swift](../GoalPet/Features/Health/HealthKitView.swift) | 独立选择/请求/读取及仅内存 Controller，离页/后台清理 | SwiftUI、Observation、HealthDataService |
| [Shared/WatchSnapshot.swift](../Shared/WatchSnapshot.swift) | 两端共享严格有界 Codable 契约、排序 reducer、缓存/本机隐藏屏障 | Foundation；编入 iPhone 与 Watch Target |
| [GoalPet/Core/Watch/PhoneWatchSync.swift](../GoalPet/Core/Watch/PhoneWatchSync.swift) | 默认关闭的最新状态发布、Int64 revision/持久 epoch、清除通知 | Combine、WatchConnectivity、WatchSnapshot |
| [GoalPet/Features/Goals/WatchSettingsView.swift](../GoalPet/Features/Goals/WatchSettingsView.swift) | 显式分享开关、行为隐私说明与排队状态 | SwiftUI、PhoneWatchSync |
| [GoalPet/Features/Dashboard/DashboardView.swift](../GoalPet/Features/Dashboard/DashboardView.swift) | 汇总首页与快速记录 | 各模块、PetCatalog、DS |
| [GoalPet/App/RootTabView.swift](../GoalPet/App/RootTabView.swift) | 五 Tab 和我的页 | 全部模块 |
| [GoalPet/App/GoalPetApp.swift](../GoalPet/App/GoalPetApp.swift) | @main、启动装配、可恢复启动错误 | Repository、AppViewModel、AppRuntimeView |
| [GoalPet/App/AppRuntimeView.swift](../GoalPet/App/AppRuntimeView.swift) | 生产启动/前台/UTC 切日刷新、Watch 会话持有与状态映射；Preview 不使用 | SwiftUI、Combine、RootTabView、PhoneWatchSync |
| [GoalPetWatch/GoalPetWatchApp.swift](../GoalPetWatch/GoalPetWatchApp.swift) | 现代单 Target watchOS App 入口与生命周期 | SwiftUI、WatchSnapshotStore |
| [GoalPetWatch/WatchSnapshotStore.swift](../GoalPetWatch/WatchSnapshotStore.swift) | 接收 application context、缓存、离线清空隐藏与显式重新启用 | Combine、WatchConnectivity、WatchSnapshotPersistence |
| [GoalPetWatch/WatchDashboardView.swift](../GoalPetWatch/WatchDashboardView.swift) | 只读任务/XP/宠物 ID、陈旧提示、Watch 本机隐私开关 | SwiftUI、WatchSnapshotStore |
| [GoalPet/Resources/PreviewHost.swift](../GoalPet/Resources/PreviewHost.swift) | 独立内存预览和示例记录 | Repository、AppViewModel |
| [GoalPet/Resources/FeaturePreviews.swift](../GoalPet/Resources/FeaturePreviews.swift) | 模块预览、深色/大字体预览 | PreviewHost、各模块 |
| [GoalPet/Resources/Localizable.xcstrings](../GoalPet/Resources/Localizable.xcstrings) | 中文源语言、部分英文结构示例 | Xcode String Catalog |
| [GoalPetTests/GoalPetTests.swift](../GoalPetTests/GoalPetTests.swift) | 47 个算法与内存仓储测试 | XCTest、GoalPet |
| [GoalPet/Core/Nutrition/FoodRecognitionContract.swift](../GoalPet/Core/Nutrition/FoodRecognitionContract.swift) | 服务协议、Codable DTO、范围和安全错误 | Foundation、L10n |
| [GoalPet/Core/Nutrition/MockFoodRecognitionService.swift](../GoalPet/Core/Nutrition/MockFoodRecognitionService.swift) | 离线固定响应和失败场景 | 识别契约 |
| [GoalPet/Core/Nutrition/FoodPhotoTransfer.swift](../GoalPet/Core/Nutrition/FoodPhotoTransfer.swift) | 系统选图文件限量读取 | CoreTransferable、Foundation、UTType |
| [GoalPet/Core/Nutrition/FoodImageProcessor.swift](../GoalPet/Core/Nutrition/FoodImageProcessor.swift) | 缩图、方向修正、JPEG 重编码、源元数据剥离 | ImageIO、UTType、识别错误 |
| [GoalPet/Core/Nutrition/RemoteFoodRecognitionService.swift](../GoalPet/Core/Nutrition/RemoteFoodRecognitionService.swift) | HTTPS 代理、会话令牌注入、限量传输、拒绝重定向 | URLSession、识别契约、PreparedFoodImage |
| [GoalPet/Features/Nutrition/FoodDraft.swift](../GoalPet/Features/Nutrition/FoodDraft.swift) | 可编辑值草稿及确认后不可变快照 | 识别契约、NumberInput |
| [GoalPet/Models/FoodModels.swift](../GoalPet/Models/FoodModels.swift) | FoodRecord/FoodItem 一对多持久模型 | SwiftData、ConfirmedFoodMeal |
| [GoalPet/Features/Nutrition/FoodRecognitionViewModel.swift](../GoalPet/Features/Nutrition/FoodRecognitionViewModel.swift) | 上传同意、异步状态、草稿编辑、确认门槛 | Observation、Service、Processor、Draft |
| [GoalPet/Features/Nutrition/FoodRecognitionView.swift](../GoalPet/Features/Nutrition/FoodRecognitionView.swift) | 选图/隐私说明/结果编辑与显式保存 | SwiftUI、PhotosUI、UIKit、ViewModels、DS |
| [GoalPet/Features/Nutrition/NutritionHistoryView.swift](../GoalPet/Features/Nutrition/NutritionHistoryView.swift) | 饮食历史、详情及确认删除 | SwiftUI、AppViewModel、FoodModels、DS |
| [GoalPetTests/FoodRecognitionTests.swift](../GoalPetTests/FoodRecognitionTests.swift) | 56 个解析、确认、图片、状态、仓储测试 | XCTest、SwiftUI、UIKit、ImageIO、SwiftData |
| [GoalPetTests/RemoteFoodRecognitionServiceTests.swift](../GoalPetTests/RemoteFoodRecognitionServiceTests.swift) | 16 个代理请求、错误映射、重试和取消测试 | XCTest、UIKit、注入式测试传输 |
| [GoalPetTests/GoalRewardEngineTests.swift](../GoalPetTests/GoalRewardEngineTests.swift) | 50 个 UTC 任务/里程碑/奖励去重/解锁测试 | XCTest、SwiftData、GoalPet |
| [GoalPetTests/GoalIntegrationTests.swift](../GoalPetTests/GoalIntegrationTests.swift) | 23 个业务与奖励写入/回滚、重启及暂停恢复集成测试 | XCTest、SwiftData、GoalPet |
| [GoalPetTests/HealthKitServiceTests.swift](../GoalPetTests/HealthKitServiceTests.swift) | 37 个归一化、睡眠并集、取消与控制器隔离测试；不是实时健康库验收 | XCTest、HealthKit、GoalPet、注入式服务/来源 |
| [GoalPetTests/WatchSnapshotTests.swift](../GoalPetTests/WatchSnapshotTests.swift) | 63 个协议边界、epoch/revision、时钟、缓存/清除/隐藏屏障测试 | XCTest、GoalPet、隔离 UserDefaults；非真实配对传输 |
| [GoalPetTests/FamilyManagementTests.swift](../GoalPetTests/FamilyManagementTests.swift) | 13 个本地重命名、归档恢复、币种隔离与失败回滚测试 | XCTest、SwiftData、GoalPet |
| [docs/FOOD_RECOGNITION.md](FOOD_RECOGNITION.md) | 识别架构、代理协议、上线边界与验收 | 无 |
| [docs/GOALS_HEALTH_WATCH.md](GOALS_HEALTH_WATCH.md) | 目标/奖励、家庭、HealthKit、Watch、签名、迁移与未执行验收 | 无 |
| [docs/FILES.md](FILES.md) | 完整文件索引、13 模型清单及关系边界 | 无 |
| [Config/GoalPet.entitlements](../Config/GoalPet.entitlements) | iPhone HealthKit entitlement；不启用后台健康交付 | iPhone 签名配置 |
| [GoalPet.xcodeproj/project.pbxproj](../GoalPet.xcodeproj/project.pbxproj) | iPhone/Test/单 Watch App Target、目录同步、伴侣嵌入、HealthKit 读取用途说明 | Xcode16+、iOS17+、watchOS10+ |
| [GoalPet.xcodeproj/xcshareddata/xcschemes/GoalPet.xcscheme](../GoalPet.xcodeproj/xcshareddata/xcschemes/GoalPet.xcscheme) | 共享 Run/Test Scheme | Xcode 工程 |
| [GoalPet.xcodeproj/xcshareddata/xcschemes/GoalPetWatch.xcscheme](../GoalPet.xcodeproj/xcshareddata/xcschemes/GoalPetWatch.xcscheme) | Watch 共享 Run/Build Scheme | Xcode 工程 |
| [.github/workflows/ios.yml](../.github/workflows/ios.yml) | iPhone 模拟器 build/test、Watch 模拟器 Debug/设备 Release 未签名构建；尚未执行 | GitHub Actions、macOS、Xcode16 |
| [.gitignore](../.gitignore) | 排除构建产物和本地用户配置 | Git |
| [README.md](../README.md) | 运行、限制、验证状态和验收清单 | 无 |

## 模型与测试计数

共 **13 个 SwiftData 模型**：

- [GoalPet/Models/Models.swift](../GoalPet/Models/Models.swift)：`UserProfile`、`FinancialAccount`、`LedgerTransaction`、`Budget`、`FamilyGroup`、`FamilyMember`、`SavingsGoal`、`SavingsContribution`、`WeightRecord`、`HealthGoal`（10）。
- [GoalPet/Models/FoodModels.swift](../GoalPet/Models/FoodModels.swift)：`FoodRecord`、`FoodItem`（2）。
- [GoalPet/Models/RewardModels.swift](../GoalPet/Models/RewardModels.swift)：`RewardEvent`（1）。HealthKit/Watch 快照是值类型，不计入模型数。

共 **305 个 XCTest 方法**：47 基线 + 72 饮食（56 + 16）+ 50 引擎 + 23 集成 + 37 HealthKit + 63 Watch + 13 家庭。本轮功能扩展新增 **186** 个；本次仅更新文档。以上为源码计数，**未执行编译、运行时测试、模拟器/真机或 CI 验证**。新增 `RewardEvent` 与 `HealthGoal.statusRaw`（以及此前饮食模型/关系）的旧库迁移未验证，不代表发布就绪。

## 关系边界

- FinancialAccount → LedgerTransaction：accountID，历史账户不能随意删除。
- SavingsGoal → SavingsContribution：goalID，余额由有效流水重算。
- FamilyGroup → FamilyMember：groupID，本地标签。
- FamilyGroup → SavingsGoal：familyGroupID，可选；nil 是个人目标。
- SavingsContribution → FamilyMember：memberID，可选；家庭贡献必须属于正确家庭。
- WeightRecord 不依赖某一 HealthGoal；修改目标不会删除历史体重。
- PetCatalog 为只读物种定义，不作为 SwiftData 实体；解锁以 `RewardEvent.petID` 为准，不是静态 Mock 解锁。
- RewardEvent 通过唯一奖励键、稳定来源 UUID 凭据和宠物 ID 关联业务，不设级联删除；只追加，业务编辑/删除/恢复不撤销已发 XP 或重复发奖。单 MainActor 写入者将业务与奖励一次保存/回滚。
- FoodRecord → FoodItem：唯一拥有关系、级联删除、可选逆向 record；不含照片，不与家庭共享。Mock 结果不得写入此关系。
- 家庭成员归档保留 UUID 与历史贡献，不能再用于新增贡献；按目标币种分别计算净额，不含初始金额/删除记录，家庭目标不发个人 XP。
- HealthKit 仅独立页面内存显示，离页/后台清理；不进仓储、不导入体重、不触发奖励、不发送到代理/家庭/Watch。
- Watch 仅接收显式 opt-in 的任务/完成状态、累计 XP、宠物 ID 与协议元数据；严格快照缓存在 Watch 的 UserDefaults，清除后保留排序屏障，不提供领取奖励或修改业务的命令通道。

不包含真实家庭权限、账号认证或同步；未来加入这些能力需要单独模型和迁移。