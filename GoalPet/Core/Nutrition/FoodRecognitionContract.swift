// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Core/Nutrition/FoodRecognitionContract.swift
// Purpose: Provider-independent Codable wire contract, validation and safe error messages.
// Dependencies: Foundation, L10n. No vendor SDK, credentials or persistence.
import Foundation

enum MealType: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breakfast: return L10n.text("早餐")
        case .lunch: return L10n.text("午餐")
        case .dinner: return L10n.text("晚餐")
        case .snack: return L10n.text("加餐")
        }
    }
}

enum FoodRecognitionMode: String, Sendable { case mock, remote, manual }

enum FoodRecognitionError: Error, LocalizedError, Equatable, Sendable {
    case offline, timeout, imageTooLarge, invalidImage, unrecognized, malformedResponse
    case unauthorized, rateLimited, serverUnavailable, cancelled, invalidConfiguration
    case consentRequired, responseTooLarge, transport, invalidInput, demoCannotPersist

    var errorDescription: String? {
        switch self {
        case .offline: return L10n.text("当前没有可用网络。照片仍在本机，可稍后重试或手动记录。")
        case .timeout: return L10n.text("识别超时，请重试或改为手动记录。")
        case .imageTooLarge: return L10n.text("图片过大，请选择较小的图片或降低分辨率后重试。")
        case .invalidImage: return L10n.text("无法读取这张图片，请重新选择 JPEG、PNG 或 HEIC 照片。")
        case .unrecognized: return L10n.text("没有识别到可用的食物，请换一张清晰照片或手动添加。")
        case .malformedResponse: return L10n.text("识别结果格式不完整，请重试或手动记录。")
        case .unauthorized: return L10n.text("识别服务登录已失效，请重新登录后再试。")
        case .rateLimited: return L10n.text("识别请求较多，请稍后再试。")
        case .serverUnavailable: return L10n.text("识别服务暂时不可用，请稍后重试。")
        case .cancelled: return L10n.text("识别已取消。")
        case .invalidConfiguration: return L10n.text("尚未正确配置安全的后端代理，请使用演示或手动记录。")
        case .consentRequired: return L10n.text("上传前请先了解处理用途，并明确同意本次上传。")
        case .responseTooLarge: return L10n.text("识别服务返回的数据过大，请稍后重试。")
        case .transport: return L10n.text("暂时无法安全连接识别服务，请重试或手动记录。")
        case .invalidInput: return L10n.text("请检查食物名称和数值。数值需非负，重量需大于零，热量下限不能超过上限。")
        case .demoCannotPersist: return L10n.text("演示结果不能写入正式饮食记录，请使用手动记录。")
        }
    }

    var code: String {
        switch self {
        case .offline: return "FOOD_OFFLINE"
        case .timeout: return "FOOD_TIMEOUT"
        case .imageTooLarge: return "FOOD_IMAGE_SIZE"
        case .invalidImage: return "FOOD_IMAGE_FORMAT"
        case .unrecognized: return "FOOD_NOT_FOUND"
        case .malformedResponse: return "FOOD_JSON"
        case .unauthorized: return "FOOD_AUTH"
        case .rateLimited: return "FOOD_RATE_LIMIT"
        case .serverUnavailable: return "FOOD_SERVER"
        case .cancelled: return "FOOD_CANCELLED"
        case .invalidConfiguration: return "FOOD_CONFIGURATION"
        case .consentRequired: return "FOOD_CONSENT"
        case .responseTooLarge: return "FOOD_RESPONSE_SIZE"
        case .transport: return "FOOD_CONNECTION"
        case .invalidInput: return "FOOD_INPUT"
        case .demoCannotPersist: return "FOOD_DEMO_ONLY"
        }
    }

    static func safe(_ error: Error) -> FoodRecognitionError {
        if let error = error as? FoodRecognitionError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .offline
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .transport
            }
        }
        return .transport
    }
}

struct CalorieRange: Codable, Equatable, Sendable {
    let lower: Double
    let upper: Double
    func validate() throws {
        guard lower.isFinite, upper.isFinite, lower >= 0, upper >= lower, upper <= 20_000 else {
            throw FoodRecognitionError.malformedResponse
        }
    }
}

struct RecognizedFood: Codable, Equatable, Sendable {
    let name: String
    let cookingMethod: String?
    let servingDescription: String?
    let estimatedWeightGrams: Double?
    let estimatedCalories: Double?
    let calorieRange: CalorieRange?
    let proteinGrams: Double?
    let carbohydrateGrams: Double?
    let fatGrams: Double?
    let confidence: Double?
    let questions: [String]?

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
              (cookingMethod?.count ?? 0) <= 120, (servingDescription?.count ?? 0) <= 200,
              (questions?.count ?? 0) <= 8, questions?.allSatisfy({ $0.count <= 300 }) ?? true else {
            throw FoodRecognitionError.malformedResponse
        }
        if let weight = estimatedWeightGrams, !weight.isFinite || weight <= 0 || weight > 20_000 {
            throw FoodRecognitionError.malformedResponse
        }
        for value in [estimatedCalories, proteinGrams, carbohydrateGrams, fatGrams].compactMap({ $0 }) {
            guard value.isFinite, value >= 0, value <= 20_000 else { throw FoodRecognitionError.malformedResponse }
        }
        if let confidence, !confidence.isFinite || !(0...1).contains(confidence) { throw FoodRecognitionError.malformedResponse }
        guard estimatedCalories != nil || calorieRange != nil else { throw FoodRecognitionError.malformedResponse }
        try calorieRange?.validate()
        if let point = estimatedCalories, let range = calorieRange,
           !(range.lower...range.upper).contains(point) { throw FoodRecognitionError.malformedResponse }
    }
}

struct FoodRecognitionResponse: Codable, Equatable, Sendable {
    let mealType: MealType
    let foods: [RecognizedFood]
    let totalEstimatedCalories: Double?
    let disclaimer: String?

    static let maximumResponseBytes = 256 * 1024
    static let maximumFoods = 30

    static func decode(_ data: Data) throws -> FoodRecognitionResponse {
        guard data.count <= maximumResponseBytes else { throw FoodRecognitionError.responseTooLarge }
        let result: FoodRecognitionResponse
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw FoodRecognitionError.malformedResponse }
        try result.validate()
        return result
    }

    func validate() throws {
        guard !foods.isEmpty else { throw FoodRecognitionError.unrecognized }
        guard foods.count <= Self.maximumFoods, (disclaimer?.count ?? 0) <= 1_000 else {
            throw FoodRecognitionError.malformedResponse
        }
        try foods.forEach { try $0.validate() }
        if let total = totalEstimatedCalories, !total.isFinite || total < 0 || total > 600_000 {
            throw FoodRecognitionError.malformedResponse
        }
        // Totals from the server are informational. UI/storage always aggregate edited items.
    }
}

struct FoodUploadNotice: Equatable, Sendable {
    let processorName: String
    let purpose: String
    let retention: String
    let privacyPolicyURL: URL
}

protocol FoodRecognitionService: Sendable {
    var mode: FoodRecognitionMode { get }
    var uploadNotice: FoodUploadNotice? { get }
    func recognize(image: PreparedFoodImage, requestID: UUID) async throws -> FoodRecognitionResponse
}