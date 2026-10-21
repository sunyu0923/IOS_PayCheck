// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Core/Nutrition/MockFoodRecognitionService.swift
// Purpose: Offline deterministic demo, using the same decoder as the proxy service.
// Dependencies: FoodRecognitionContract, PreparedFoodImage. No networking or database writes.
import Foundation

struct MockFoodRecognitionService: FoodRecognitionService {
    enum Scenario: Sendable { case success, rangeOnly, offline, timeout, unrecognized }
    let mode = FoodRecognitionMode.mock
    let uploadNotice: FoodUploadNotice? = nil
    let scenario: Scenario
    let delayNanoseconds: UInt64

    init(scenario: Scenario = .success, delayNanoseconds: UInt64 = 350_000_000) {
        self.scenario = scenario; self.delayNanoseconds = delayNanoseconds
    }

    func recognize(image: PreparedFoodImage, requestID: UUID) async throws -> FoodRecognitionResponse {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try Task.checkCancellation()
        switch scenario {
        case .offline: throw FoodRecognitionError.offline
        case .timeout: throw FoodRecognitionError.timeout
        case .unrecognized: throw FoodRecognitionError.unrecognized
        case .success: return try FoodRecognitionResponse.decode(Data(Self.sampleJSON.utf8))
        case .rangeOnly: return try FoodRecognitionResponse.decode(Data(Self.rangeJSON.utf8))
        }
    }

    static let sampleJSON = """
    {
      "mealType": "lunch",
      "foods": [
        {"name":"米饭","cookingMethod":"蒸煮","servingDescription":"一碗（示例）",
         "estimatedWeightGrams":180,"estimatedCalories":210,
         "proteinGrams":4.5,"carbohydrateGrams":46,"fatGrams":0.5,"confidence":0.86,
         "questions":["请确认实际分量；此处是固定演示数据。"]},
        {"name":"番茄炒蛋","cookingMethod":"炒","estimatedWeightGrams":220,
         "estimatedCalories":280,"proteinGrams":15,"carbohydrateGrams":12,"fatGrams":19,"confidence":0.68}
      ],
      "totalEstimatedCalories":490,
      "disclaimer":"固定演示结果，并非对所选照片的识别。"
    }
    """

    static let rangeJSON = """
    {
      "mealType":"dinner",
      "foods":[{"name":"混合餐盘（示例）","calorieRange":{"lower":350,"upper":650},
      "questions":["请补充分量或实际克数。"],"confidence":0.4}],
      "disclaimer":"无法从图片准确判断分量，保留估算范围，不自动取中点。"
    }
    """
}