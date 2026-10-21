# 文件交付清单

所有 Swift 文件头均注明完整生成路径、用途和依赖。下面按构建依赖顺序列出文件；完整路径由开发机根目录加所列的完整仓库相对路径组成。迁移到 Mac 不需要保留 Windows 路径，源码注释路径不参与构建。

开发机根目录：C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/

| 文件 | 用途 | 依赖 |
|---|---|---|
| [GoalPet/Core/DesignSystem.swift](../GoalPet/Core/DesignSystem.swift) | DS 语义色、卡片、错误提示、主题、本地化入口 | SwiftUI、UIKit |
| [GoalPet/Models/Models.swift](../GoalPet/Models/Models.swift) | 十个本地 SwiftData 模型和 String 枚举 | SwiftData、L10n |
| [GoalPet/Core/Calculations.swift](../GoalPet/Core/Calculations.swift) | 金额、日期周期、进度、BMR/TDEE/BMI、移动平均 | Foundation、领域枚举 |
| [GoalPet/Core/LocalRepository.swift](../GoalPet/Core/LocalRepository.swift) | 本地容器、快照、提交与回滚 | 全部 Models |
| [GoalPet/App/AppViewModel.swift](../GoalPet/App/AppViewModel.swift) | 输入校验、跨页面状态、业务操作 | Repository、Calculations |
| [GoalPet/Resources/PetCatalog.swift](../GoalPet/Resources/PetCatalog.swift) | 三只 Mock 物种和像素绘制 | SwiftUI、DS |
| [GoalPet/Features/Pets/PetCollectionView.swift](../GoalPet/Features/Pets/PetCollectionView.swift) | 只读图鉴与宠物详情 | PetCatalog、DS |
| [GoalPet/Features/Finance/FinanceView.swift](../GoalPet/Features/Finance/FinanceView.swift) | 账单列表/编辑/恢复、预算 | AppViewModel、SavingsGoalView、DS |
| [GoalPet/Features/Savings/SavingsGoalView.swift](../GoalPet/Features/Savings/SavingsGoalView.swift) | 个人/家庭目标列表、详情、编辑、资金记录 | AppViewModel、Calculations、DS |
| [GoalPet/Features/Health/HealthDashboardView.swift](../GoalPet/Features/Health/HealthDashboardView.swift) | 健康首页、图表、体重/资料/目标表单 | AppViewModel、Charts、DS |
| [GoalPet/Features/Family/FamilyView.swift](../GoalPet/Features/Family/FamilyView.swift) | 本地家庭/成员/共同目标入口 | AppViewModel、SavingsGoalView、DS |
| [GoalPet/Features/Dashboard/DashboardView.swift](../GoalPet/Features/Dashboard/DashboardView.swift) | 汇总首页与快速记录 | 各模块、PetCatalog、DS |
| [GoalPet/App/RootTabView.swift](../GoalPet/App/RootTabView.swift) | 五 Tab 和我的页 | 全部模块 |
| [GoalPet/App/GoalPetApp.swift](../GoalPet/App/GoalPetApp.swift) | @main、启动装配、可恢复启动错误 | Repository、AppViewModel、RootTabView |
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
| [docs/FOOD_RECOGNITION.md](FOOD_RECOGNITION.md) | 识别架构、代理协议、上线边界与验收 | 无 |
| [GoalPet.xcodeproj/project.pbxproj](../GoalPet.xcodeproj/project.pbxproj) | App/Test Target、目录同步、iOS17 配置 | Xcode16+ |
| [GoalPet.xcodeproj/xcshareddata/xcschemes/GoalPet.xcscheme](../GoalPet.xcodeproj/xcshareddata/xcschemes/GoalPet.xcscheme) | 共享 Run/Test Scheme | Xcode 工程 |
| [.github/workflows/ios.yml](../.github/workflows/ios.yml) | macOS 构建和 XCTest 流程 | GitHub Actions、Xcode16 |
| [.gitignore](../.gitignore) | 排除构建产物和本地用户配置 | Git |
| [README.md](../README.md) | 运行、限制、验证状态和验收清单 | 无 |

## 关系边界

- FinancialAccount → LedgerTransaction：accountID，历史账户不能随意删除。
- SavingsGoal → SavingsContribution：goalID，余额由有效流水重算。
- FamilyGroup → FamilyMember：groupID，本地标签。
- FamilyGroup → SavingsGoal：familyGroupID，可选；nil 是个人目标。
- SavingsContribution → FamilyMember：memberID，可选；家庭贡献必须属于正确家庭。
- WeightRecord 不依赖某一 HealthGoal；修改目标不会删除历史体重。
- PetCatalog 为只读 Mock，不进入生产 SwiftData 存储。
- FoodRecord → FoodItem：唯一拥有关系、级联删除、可选逆向 record；不含照片，不与家庭共享。Mock 结果不得写入此关系。

不包含真实家庭权限、账号认证或同步；未来加入这些能力需要单独模型和迁移。