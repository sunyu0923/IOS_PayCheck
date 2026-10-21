// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPetTests/FoodRecognitionTests.swift
// Purpose: Offline contract, confirmation, observable draft, persistence, image and mock regression tests.
// Dependencies: XCTest, Foundation, SwiftData, SwiftUI, UIKit, ImageIO, UniformTypeIdentifiers, @testable GoalPet; iOS 17+, Swift 5.

import Foundation
import ImageIO
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import GoalPet

private enum FoodTestFixtures {
    // A past instant also works with confirmedMeal(), whose clock is not injectable.
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func responseData(
        food: [String: Any] = ["name": "Rice", "estimatedCalories": 100],
        overrides: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = ["mealType": "lunch", "foods": [food]]
        object.merge(overrides) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func food(
        weight: Double? = nil, calories: Double? = 100, range: CalorieRange? = nil,
        protein: Double? = nil, carbohydrate: Double? = nil, fat: Double? = nil,
        confidence: Double? = nil
    ) -> RecognizedFood {
        RecognizedFood(
            name: "Rice", cookingMethod: nil, servingDescription: nil,
            estimatedWeightGrams: weight, estimatedCalories: calories, calorieRange: range,
            proteinGrams: protein, carbohydrateGrams: carbohydrate, fatGrams: fat,
            confidence: confidence, questions: nil
        )
    }

    static func draft(name: String = "Rice", calories: String = "100") -> EditableFoodItem {
        var item = EditableFoodItem()
        item.name = name
        item.caloriesText = calories
        return item
    }

    static func confirm(
        _ drafts: [EditableFoodItem], userConfirmed: Bool = true,
        date: Date = FoodTestFixtures.now, source: FoodRecognitionMode = .manual
    ) throws -> ConfirmedFoodMeal {
        try ConfirmedFoodMeal.confirm(
            id: UUID(), mealType: .lunch, date: date, source: source,
            drafts: drafts, userConfirmed: userConfirmed, now: now
        )
    }

    @MainActor
    static func imageData(jpeg: Bool, size: CGSize = CGSize(width: 64, height: 48)) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
        }
        return try XCTUnwrap(jpeg ? image.jpegData(compressionQuality: 0.9) : image.pngData())
    }

    @MainActor
    static func addingGPS(to data: Data) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"
        ]
        let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

// Count explicit commits as well as inspecting the underlying in-memory store.
// LocalRepository's operational profile/account defaults are not food writes.
@MainActor
private final class FoodTestRepository: AppRepository {
    let local: LocalRepository
    private(set) var commitCount = 0

    init() throws {
        let container = try LocalRepository.makeContainer(inMemory: true)
        local = try LocalRepository(container: container)
    }

    func load() throws -> AppSnapshot { try local.load() }

    func commit(_ mutation: (ModelContext) throws -> Void) throws -> AppSnapshot {
        commitCount += 1
        return try local.commit(mutation)
    }
}

// Deliberately ignores cancellation: only the test can finish a request. The entry
// expectation is fulfilled AFTER installing its continuation, never by a timer.
private actor SuspendedFoodTestRemoteService: FoodRecognitionService {
    nonisolated let mode = FoodRecognitionMode.remote
    nonisolated let uploadNotice: FoodUploadNotice?
    private let entered: [XCTestExpectation]
    private(set) var callCount = 0
    private var pending: [Int: CheckedContinuation<FoodRecognitionResponse, Error>] = [:]
    private var earlyResults: [Int: Result<FoodRecognitionResponse, FoodRecognitionError>] = [:]

    init(notice: FoodUploadNotice?, entered: [XCTestExpectation] = []) {
        uploadNotice = notice
        self.entered = entered
    }

    func recognize(image: PreparedFoodImage, requestID: UUID) async throws -> FoodRecognitionResponse {
        let call = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
            if entered.indices.contains(call) { entered[call].fulfill() }
            if let result = earlyResults.removeValue(forKey: call) {
                resolve(call: call, with: result)
            }
        }
    }

    func resolve(call: Int, with result: Result<FoodRecognitionResponse, FoodRecognitionError>) {
        guard let continuation = pending.removeValue(forKey: call) else {
            // Also allows teardown to finish a request if an entry expectation timed out.
            earlyResults[call] = result
            return
        }
        switch result {
        case .success(let response): continuation.resume(returning: response)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

// Include both stored and computed UI state so a stale completion cannot silently
// clobber a newer draft, photo, error, review gate, consent, or busy indicator.
private struct FoodTestWorkflowState: Equatable {
    let imageData: Data?
    let isPreparing: Bool
    let isRecognizing: Bool
    let error: FoodRecognitionError?
    let source: FoodRecognitionMode
    let hasDraft: Bool
    let isSaved: Bool
    let demoResult: ConfirmedFoodMeal?
    let draftID: UUID
    let hasReviewed: Bool
    let uploadConsent: Bool
    let items: [EditableFoodItem]
    let mealType: MealType
    let date: Date
    let canRecognize: Bool
    let canConfirm: Bool

    @MainActor
    init(_ vm: FoodRecognitionViewModel) {
        imageData = vm.imageData; isPreparing = vm.isPreparing; isRecognizing = vm.isRecognizing
        error = vm.error; source = vm.source; hasDraft = vm.hasDraft; isSaved = vm.isSaved
        demoResult = vm.demoResult; draftID = vm.draftID; hasReviewed = vm.hasReviewed
        uploadConsent = vm.uploadConsent; items = vm.items; mealType = vm.mealType; date = vm.date
        canRecognize = vm.canRecognize; canConfirm = vm.canConfirm
    }
}

final class FoodRecognitionTests: XCTestCase {
    private func assertFoodError<T>(
        _ expected: FoodRecognitionError, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), message, file: file, line: line) { error in
            XCTAssertEqual(error as? FoodRecognitionError, expected, message, file: file, line: line)
        }
    }

    @MainActor
    private func makeStore() throws -> (repository: FoodTestRepository, app: AppViewModel) {
        let repository = try FoodTestRepository()
        let app = try AppViewModel(
            repository: repository, now: { FoodTestFixtures.now },
            foodRecognitionService: MockFoodRecognitionService(delayNanoseconds: 0)
        )
        return (repository, app)
    }

    @MainActor
    private func assertMealCounts(
        _ repository: FoodTestRepository, records: Int, items: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // A fresh context verifies saved rows rather than only the app's cached snapshot.
        let context = ModelContext(repository.local.container)
        context.autosaveEnabled = false
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodRecord>()), records, file: file, line: line)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FoodItem>()), items, file: file, line: line)
    }

    @MainActor
    private func assertPreparedImage(
        _ prepared: PreparedFoodImage, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertFalse(prepared.jpegData.isEmpty, file: file, line: line)
        XCTAssertLessThanOrEqual(prepared.jpegData.count, FoodImageProcessor.maximumUploadBytes, file: file, line: line)
        XCTAssertGreaterThan(prepared.width, 0, file: file, line: line)
        XCTAssertGreaterThan(prepared.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(prepared.width, 1_600, file: file, line: line)
        XCTAssertLessThanOrEqual(prepared.height, 1_600, file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.jpegData as CFData, nil), file: file, line: line)
        let type = try XCTUnwrap(CGImageSourceGetType(source), file: file, line: line)
        XCTAssertEqual(type as String, UTType.jpeg.identifier, file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(image.width, prepared.width, file: file, line: line)
        XCTAssertEqual(image.height, prepared.height, file: file, line: line)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], file: file, line: line
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], file: file, line: line)
    }

    // MARK: - Wire contract

    @MainActor
    func testSampleJSONDecodesNamesWeightsCaloriesAndMacros() throws {
        let response = try FoodRecognitionResponse.decode(Data(MockFoodRecognitionService.sampleJSON.utf8))
        XCTAssertEqual(response.mealType, .lunch)
        XCTAssertEqual(response.foods.count, 2)
        let rice = try XCTUnwrap(response.foods.first)
        let eggs = try XCTUnwrap(response.foods.last)
        XCTAssertEqual(rice.name, "米饭")
        XCTAssertEqual(rice.cookingMethod, "蒸煮")
        XCTAssertEqual(rice.servingDescription, "一碗（示例）")
        XCTAssertEqual(rice.estimatedWeightGrams, 180)
        XCTAssertEqual(rice.estimatedCalories, 210)
        XCTAssertEqual(rice.proteinGrams, 4.5)
        XCTAssertEqual(rice.carbohydrateGrams, 46)
        XCTAssertEqual(rice.fatGrams, 0.5)
        XCTAssertEqual(rice.confidence, 0.86)
        XCTAssertEqual(rice.questions, ["请确认实际分量；此处是固定演示数据。"])
        XCTAssertEqual(eggs.name, "番茄炒蛋")
        XCTAssertEqual(eggs.cookingMethod, "炒")
        XCTAssertEqual(eggs.estimatedWeightGrams, 220)
        XCTAssertEqual(eggs.estimatedCalories, 280)
        XCTAssertEqual(eggs.proteinGrams, 15)
        XCTAssertEqual(eggs.carbohydrateGrams, 12)
        XCTAssertEqual(eggs.fatGrams, 19)
        XCTAssertEqual(eggs.confidence, 0.68)
        XCTAssertEqual(response.totalEstimatedCalories, 490)
        XCTAssertEqual(response.disclaimer, "固定演示结果，并非对所选照片的识别。")
    }

    @MainActor
    func testCodableRoundTripPreservesSampleAndRangeOnlyResponses() throws {
        for json in [MockFoodRecognitionService.sampleJSON, MockFoodRecognitionService.rangeJSON] {
            let original = try FoodRecognitionResponse.decode(Data(json.utf8))
            let encoded = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(FoodRecognitionResponse.self, from: encoded), original)
            XCTAssertEqual(try FoodRecognitionResponse.decode(encoded), original)
        }
    }

    @MainActor
    func testRangeOnlyPreservesUnknownValuesThroughConfirmation() throws {
        let response = try FoodRecognitionResponse.decode(Data(MockFoodRecognitionService.rangeJSON.utf8))
        let food = try XCTUnwrap(response.foods.first)
        XCTAssertEqual(response.mealType, .dinner)
        XCTAssertEqual(food.calorieRange, CalorieRange(lower: 350, upper: 650))
        XCTAssertNil(food.estimatedWeightGrams)
        XCTAssertNil(food.estimatedCalories)
        XCTAssertNil(food.proteinGrams)
        XCTAssertNil(food.carbohydrateGrams)
        XCTAssertNil(food.fatGrams)
        XCTAssertNil(response.totalEstimatedCalories)
        let draft = EditableFoodItem(food: food, isAIRecognized: true)
        XCTAssertEqual(draft.weightText, "")
        XCTAssertEqual(draft.caloriesText, "")
        XCTAssertEqual(draft.proteinText, "")
        XCTAssertEqual(draft.carbohydrateText, "")
        XCTAssertEqual(draft.fatText, "")
        let meal = try FoodTestFixtures.confirm([draft], source: .remote)
        let value = try XCTUnwrap(meal.foods.first)
        XCTAssertNil(value.weightGrams)
        XCTAssertNil(value.calories) // Never invent a midpoint of 500.
        XCTAssertNil(value.proteinGrams)
        XCTAssertNil(value.carbohydrateGrams)
        XCTAssertNil(value.fatGrams)
        XCTAssertEqual(value.calorieRange, food.calorieRange)
        XCTAssertTrue(value.isAIRecognized)
    }

    @MainActor
    func testMalformedJSONUnknownMealAndMissingRequiredFieldsAreRejected() {
        let malformed = [
            "", "{", "[]",
            #"{"mealType":"brunch","foods":[{"name":"Rice","estimatedCalories":100}]}"#,
            #"{"foods":[{"name":"Rice","estimatedCalories":100}]}"#,
            #"{"mealType":"lunch"}"#,
            #"{"mealType":"lunch","foods":null}"#,
            #"{"mealType":"lunch","foods":[{"estimatedCalories":100}]}"#,
            #"{"mealType":"lunch","foods":[{"name":null,"estimatedCalories":100}]}"#
        ]
        for json in malformed {
            assertFoodError(.malformedResponse, json) {
                try FoodRecognitionResponse.decode(Data(json.utf8))
            }
        }
    }

    @MainActor
    func testStringNumbersAreNotCoerced() throws {
        for field in ["estimatedWeightGrams", "estimatedCalories", "proteinGrams",
                      "carbohydrateGrams", "fatGrams", "confidence"] {
            var food: [String: Any] = ["name": "Rice", "estimatedCalories": 100]
            food[field] = "1"
            let data = try FoodTestFixtures.responseData(food: food)
            assertFoodError(.malformedResponse, field) { try FoodRecognitionResponse.decode(data) }
        }
        let ranges: [[String: Any]] = [["lower": "0", "upper": 100], ["lower": 0, "upper": "100"]]
        for range in ranges {
            let data = try FoodTestFixtures.responseData(food: ["name": "Rice", "calorieRange": range])
            assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(data) }
        }
        let data = try FoodTestFixtures.responseData(overrides: ["totalEstimatedCalories": "100"])
        assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(data) }
    }

    @MainActor
    func testEmptyFoodsIsUnrecognizedRatherThanMalformed() throws {
        let data = try FoodTestFixtures.responseData(overrides: ["foods": []])
        assertFoodError(.unrecognized) { try FoodRecognitionResponse.decode(data) }
    }

    @MainActor
    func testNegativeAndExcessiveNumericFieldsAreRejected() throws {
        for field in ["estimatedWeightGrams", "estimatedCalories", "proteinGrams", "carbohydrateGrams", "fatGrams"] {
            for value in [-1, 20_001] {
                var food: [String: Any] = ["name": "Rice", "estimatedCalories": 100]
                food[field] = value
                let data = try FoodTestFixtures.responseData(food: food)
                assertFoodError(.malformedResponse, "\(field)=\(value)") { try FoodRecognitionResponse.decode(data) }
            }
        }
        let zeroWeight = try FoodTestFixtures.responseData(food: ["name": "Rice", "estimatedCalories": 0, "estimatedWeightGrams": 0])
        assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(zeroWeight) }
        for total in [-1, 600_001] {
            let data = try FoodTestFixtures.responseData(overrides: ["totalEstimatedCalories": total])
            assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(data) }
        }
    }

    @MainActor
    func testNonfiniteJSONRepresentationsAreRejected() {
        for token in ["NaN", "Infinity", "-Infinity", "1e999", #""NaN""#, #""Infinity""#] {
            let json = "{\"mealType\":\"lunch\",\"foods\":[{\"name\":\"Rice\",\"estimatedCalories\":\(token)}]}"
            assertFoodError(.malformedResponse, token) { try FoodRecognitionResponse.decode(Data(json.utf8)) }
        }
    }

    @MainActor
    func testValidationRejectsNonfiniteValuesEvenWithoutJSONDecoding() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            let foods = [
                FoodTestFixtures.food(weight: value), FoodTestFixtures.food(calories: value),
                FoodTestFixtures.food(protein: value), FoodTestFixtures.food(carbohydrate: value),
                FoodTestFixtures.food(fat: value), FoodTestFixtures.food(confidence: value),
                FoodTestFixtures.food(range: CalorieRange(lower: value, upper: 200)),
                FoodTestFixtures.food(range: CalorieRange(lower: 0, upper: value))
            ]
            for food in foods {
                assertFoodError(.malformedResponse) { try food.validate() }
            }
            let response = FoodRecognitionResponse(
                mealType: .lunch, foods: [FoodTestFixtures.food()],
                totalEstimatedCalories: value, disclaimer: nil
            )
            assertFoodError(.malformedResponse) { try response.validate() }
        }
    }

    @MainActor
    func testInvalidConfidenceReversedRangesAndOutOfRangePointsAreRejected() throws {
        for confidence in [-0.01, 1.01] {
            let data = try FoodTestFixtures.responseData(food: ["name": "Rice", "estimatedCalories": 100, "confidence": confidence])
            assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(data) }
        }
        for (lower, upper) in [(-1, 200), (200, 100), (0, 20_001)] {
            let data = try FoodTestFixtures.responseData(food: [
                "name": "Rice", "calorieRange": ["lower": lower, "upper": upper]
            ])
            assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(data) }
        }
        for point in [99, 201] {
            let data = try FoodTestFixtures.responseData(food: [
                "name": "Rice", "estimatedCalories": point, "calorieRange": ["lower": 100, "upper": 200]
            ])
            assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(data) }
        }
        let noEstimate = try FoodTestFixtures.responseData(food: ["name": "Rice"])
        assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(noEstimate) }
    }

    @MainActor
    func testExcessiveTextQuestionsAndFoodCountsAreRejected() throws {
        let changes: [(String, Any)] = [
            ("name", " \n\t"), ("name", String(repeating: "x", count: 121)),
            ("cookingMethod", String(repeating: "x", count: 121)),
            ("servingDescription", String(repeating: "x", count: 201)),
            ("questions", Array(repeating: "Question", count: 9)),
            ("questions", [String(repeating: "x", count: 301)])
        ]
        for (field, value) in changes {
            var food: [String: Any] = ["name": "Rice", "estimatedCalories": 100]
            food[field] = value
            let data = try FoodTestFixtures.responseData(food: food)
            assertFoodError(.malformedResponse, field) { try FoodRecognitionResponse.decode(data) }
        }
        let disclaimer = try FoodTestFixtures.responseData(overrides: ["disclaimer": String(repeating: "x", count: 1_001)])
        assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(disclaimer) }
        let foods = Array(repeating: ["name": "Rice", "estimatedCalories": 100] as [String: Any], count: 31)
        let tooMany = try FoodTestFixtures.responseData(overrides: ["foods": foods])
        assertFoodError(.malformedResponse) { try FoodRecognitionResponse.decode(tooMany) }
    }

    @MainActor
    func testInclusiveContractLimitsAndZeroNutrientsAreAccepted() throws {
        let food: [String: Any] = [
            "name": String(repeating: "x", count: 120), "cookingMethod": String(repeating: "x", count: 120),
            "servingDescription": String(repeating: "x", count: 200),
            "questions": Array(repeating: String(repeating: "x", count: 300), count: 8),
            "estimatedWeightGrams": 20_000, "estimatedCalories": 20_000,
            "calorieRange": ["lower": 20_000, "upper": 20_000],
            "proteinGrams": 0, "carbohydrateGrams": 20_000, "fatGrams": 0, "confidence": 1
        ]
        let data = try FoodTestFixtures.responseData(overrides: [
            "foods": Array(repeating: food, count: 30), "totalEstimatedCalories": 600_000,
            "disclaimer": String(repeating: "x", count: 1_000)
        ])
        let response = try FoodRecognitionResponse.decode(data)
        XCTAssertEqual(response.foods.count, FoodRecognitionResponse.maximumFoods)
        XCTAssertEqual(response.foods.first?.proteinGrams, 0)
        XCTAssertNoThrow(try FoodTestFixtures.food(calories: 0, range: CalorieRange(lower: 0, upper: 0), confidence: 0).validate())
    }

    @MainActor
    func testResponseByteLimitAcceptsExactBoundaryAndRejectsOneByteOver() throws {
        var data = try FoodTestFixtures.responseData()
        data.append(Data(repeating: 0x20, count: FoodRecognitionResponse.maximumResponseBytes - data.count))
        XCTAssertEqual(data.count, FoodRecognitionResponse.maximumResponseBytes)
        XCTAssertEqual(try FoodRecognitionResponse.decode(data).foods.count, 1)
        data.append(0x20)
        assertFoodError(.responseTooLarge) { try FoodRecognitionResponse.decode(data) }
        let oversizedGarbage = Data(repeating: 0xFF, count: FoodRecognitionResponse.maximumResponseBytes + 1)
        assertFoodError(.responseTooLarge) { try FoodRecognitionResponse.decode(oversizedGarbage) }
    }

    @MainActor
    func testUnknownExtraKeysAreAllowedAtEveryObjectLevel() throws {
        let data = try FoodTestFixtures.responseData(food: [
            "name": "Rice", "estimatedCalories": 100,
            "futureFoodField": ["enabled": true],
            "calorieRange": ["lower": 50, "upper": 150, "futureRangeField": 999]
        ], overrides: ["futureResponseField": ["version": 2]])
        let response = try FoodRecognitionResponse.decode(data)
        let food = try XCTUnwrap(response.foods.first)
        XCTAssertEqual(food.name, "Rice")
        XCTAssertEqual(food.estimatedCalories, 100)
        XCTAssertEqual(food.calorieRange, CalorieRange(lower: 50, upper: 150))
    }

    // MARK: - Confirmation and editable values

    @MainActor
    func testUnchangedRecognizedDraftPreservesOriginalNumericPrecision() throws {
        let precise = 0.12345678901234567
        let foods = [
            FoodTestFixtures.food(weight: 0.001, calories: 0.0015,
                                  range: CalorieRange(lower: 0.001, upper: 0.002),
                                  protein: 0.001, carbohydrate: 0.001, fat: 0.001),
            FoodTestFixtures.food(weight: precise, calories: precise,
                                  protein: precise, carbohydrate: precise, fat: precise)
        ]
        for food in foods {
            var draft = EditableFoodItem(food: food, isAIRecognized: true)
            draft.name = "Renamed without editing numbers"
            let meal = try FoodTestFixtures.confirm([draft], source: .remote)
            let value = try XCTUnwrap(meal.foods.first)
            // Exact equality is intentional: display formatting must not round stored values.
            XCTAssertEqual(value.weightGrams, food.estimatedWeightGrams)
            XCTAssertEqual(value.calories, food.estimatedCalories)
            XCTAssertEqual(value.calorieRange, food.calorieRange)
            XCTAssertEqual(value.proteinGrams, food.proteinGrams)
            XCTAssertEqual(value.carbohydrateGrams, food.carbohydrateGrams)
            XCTAssertEqual(value.fatGrams, food.fatGrams)
        }
    }

    @MainActor
    func testEditedRecognizedDraftUsesNewParsedNumbersInsteadOfOriginals() throws {
        let food = FoodTestFixtures.food(weight: 0.001, calories: 0.0015,
                                        range: CalorieRange(lower: 0.001, upper: 0.002),
                                        protein: 0.001, carbohydrate: 0.001, fat: 0.001)
        var draft = EditableFoodItem(food: food, isAIRecognized: true)
        draft.weightText = "2.125"
        draft.caloriesText = "10.125"
        draft.lowerCaloriesText = "10.001"
        draft.upperCaloriesText = "10.999"
        draft.proteinText = "0.123"
        draft.carbohydrateText = "0.456"
        draft.fatText = "0.789"
        let meal = try FoodTestFixtures.confirm([draft], source: .remote)
        let value = try XCTUnwrap(meal.foods.first)
        XCTAssertEqual(value.weightGrams, 2.125)
        XCTAssertEqual(value.calories, 10.125)
        XCTAssertEqual(value.calorieRange, CalorieRange(lower: 10.001, upper: 10.999))
        XCTAssertEqual(value.proteinGrams, 0.123)
        XCTAssertEqual(value.carbohydrateGrams, 0.456)
        XCTAssertEqual(value.fatGrams, 0.789)
    }

    @MainActor
    func testConfirmationRejectsMissingConsentEmptyFutureAndMalformedDrafts() {
        let valid = FoodTestFixtures.draft()
        assertFoodError(.consentRequired) { try FoodTestFixtures.confirm([valid], userConfirmed: false) }
        assertFoodError(.invalidInput) { try FoodTestFixtures.confirm([]) }
        assertFoodError(.invalidInput) {
            try FoodTestFixtures.confirm([valid], date: FoodTestFixtures.now.addingTimeInterval(1))
        }
        assertFoodError(.invalidInput) { try FoodTestFixtures.confirm([EditableFoodItem()]) }
        assertFoodError(.invalidInput) { try FoodTestFixtures.confirm([FoodTestFixtures.draft(calories: "oops")]) }
    }

    @MainActor
    func testConfirmationRejectsDuplicateIDsAndExcessiveItems() throws {
        let item = FoodTestFixtures.draft()
        assertFoodError(.invalidInput) { try FoodTestFixtures.confirm([item, item]) }
        let maximum = (0..<FoodRecognitionResponse.maximumFoods).map { _ in FoodTestFixtures.draft() }
        XCTAssertEqual(try FoodTestFixtures.confirm(maximum).foods.count, 30)
        assertFoodError(.invalidInput) { try FoodTestFixtures.confirm(maximum + [FoodTestFixtures.draft()]) }
    }

    @MainActor
    func testDraftNumericFieldsRejectMalformedNegativeNonfiniteAndExcessiveText() {
        let fields: [WritableKeyPath<EditableFoodItem, String>] = [
            \.weightText, \.caloriesText, \.proteinText, \.carbohydrateText, \.fatText,
            \.lowerCaloriesText, \.upperCaloriesText
        ]
        for field in fields {
            for text in ["-1", "NaN", "Infinity", "1e999", "20001", "12abc"] {
                var draft = FoodTestFixtures.draft()
                draft[keyPath: field] = text
                assertFoodError(.invalidInput, text) { try FoodTestFixtures.confirm([draft]) }
            }
        }
        var zeroWeight = FoodTestFixtures.draft()
        zeroWeight.weightText = "0"
        assertFoodError(.invalidInput) { try FoodTestFixtures.confirm([zeroWeight]) }
    }

    @MainActor
    func testDraftRejectsPartialReversedAndInconsistentCalorieRanges() {
        for (lower, upper, point) in [("100", "", ""), ("", "200", ""), ("200", "100", ""),
                                      ("100", "200", "99"), ("100", "200", "201")] {
            var draft = FoodTestFixtures.draft(calories: point)
            draft.lowerCaloriesText = lower
            draft.upperCaloriesText = upper
            assertFoodError(.invalidInput) { try FoodTestFixtures.confirm([draft]) }
        }
    }

    @MainActor
    func testDraftRejectsInvalidNamesAndExcessiveDescriptions() {
        let fields: [(WritableKeyPath<EditableFoodItem, String>, String)] = [
            (\.name, " \n\t"), (\.name, String(repeating: "x", count: 121)),
            (\.cookingMethod, String(repeating: "x", count: 121)),
            (\.servingDescription, String(repeating: "x", count: 201))
        ]
        for (field, text) in fields {
            var draft = FoodTestFixtures.draft()
            draft[keyPath: field] = text
            assertFoodError(.invalidInput) { try FoodTestFixtures.confirm([draft]) }
        }
    }

    @MainActor
    func testManualDraftTrimsNameAndPreservesNilRatherThanZero() throws {
        var draft = FoodTestFixtures.draft(name: " \nRice\t ", calories: " ")
        draft.weightText = "\n"
        draft.proteinText = "\t"
        let value = try draft.validated()
        XCTAssertEqual(value.name, "Rice")
        XCTAssertEqual(value.id, draft.id)
        XCTAssertNil(value.weightGrams)
        XCTAssertNil(value.calories)
        XCTAssertNil(value.calorieRange)
        XCTAssertNil(value.proteinGrams)
        XCTAssertNil(value.carbohydrateGrams)
        XCTAssertNil(value.fatGrams)
        XCTAssertFalse(value.isAIRecognized)
        draft.caloriesText = "0"
        draft.proteinText = "0"
        let zero = try draft.validated()
        XCTAssertEqual(zero.calories, 0)
        XCTAssertEqual(zero.proteinGrams, 0)
        XCTAssertNil(zero.fatGrams)
    }

    @MainActor
    func testConfirmedMealIsAnImmutableSnapshotWithStableItemIDs() throws {
        var draft = FoodTestFixtures.draft()
        let meal = try FoodTestFixtures.confirm([draft])
        draft.name = "Edited later"
        draft.caloriesText = "200"
        let savedValue = try XCTUnwrap(meal.foods.first)
        XCTAssertEqual(savedValue.id, draft.id)
        XCTAssertEqual(savedValue.name, "Rice")
        XCTAssertEqual(savedValue.calories, 100)
        XCTAssertEqual(meal.date, FoodTestFixtures.now)
        XCTAssertEqual(meal.mealType, .lunch)
        XCTAssertEqual(meal.source, .manual)
    }

    // MARK: - View model and isolated persistence

    @MainActor
    func testItemAddDeleteAndEditProduceTheConfirmedContents() throws {
        let vm = FoodRecognitionViewModel(service: MockFoodRecognitionService(delayNanoseconds: 0))
        vm.startManual()
        vm.date = FoodTestFixtures.now
        let removedID = try XCTUnwrap(vm.items.first?.id)
        vm.addItem()
        XCTAssertEqual(vm.items.count, 2)
        let retainedID = try XCTUnwrap(vm.items.last?.id)
        vm.removeItem(id: removedID)
        XCTAssertEqual(vm.items.count, 1)
        let index = try XCTUnwrap(vm.items.firstIndex(where: { $0.id == retainedID }))
        vm.items[index].name = "Edited rice"
        vm.items[index].caloriesText = "125"
        vm.items[index].proteinText = "5"
        vm.hasReviewed = true
        let meal = try vm.confirmedMeal()
        let value = try XCTUnwrap(meal.foods.first)
        XCTAssertEqual(value.id, retainedID)
        XCTAssertEqual(value.name, "Edited rice")
        XCTAssertEqual(value.calories, 125)
        XCTAssertEqual(value.proteinGrams, 5)
        XCTAssertNil(value.fatGrams)
        vm.removeItem(id: retainedID)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(vm.canConfirm)
        assertFoodError(.invalidInput) { try vm.confirmedMeal() }
    }

    @MainActor
    func testEditingObservableArrayElementClearsReviewViaDidSet() throws {
        let vm = FoodRecognitionViewModel(service: MockFoodRecognitionService(delayNanoseconds: 0))
        vm.startManual()
        vm.date = FoodTestFixtures.now
        vm.items = [FoodTestFixtures.draft()]
        vm.hasReviewed = true
        XCTAssertTrue(vm.canConfirm)
        let index = try XCTUnwrap(vm.items.indices.first)
        // Nested value mutation must write back through @Observable's items setter.
        vm.items[index].caloriesText = "150"
        XCTAssertFalse(vm.hasReviewed)
        XCTAssertFalse(vm.canConfirm)
        assertFoodError(.invalidInput) { try vm.confirmedMeal() }
        vm.hasReviewed = true
        XCTAssertEqual(try vm.confirmedMeal().foods.first?.calories, 150)
    }

    @MainActor
    func testSwiftUIBindableProjectedArrayElementFieldEditClearsReview() throws {
        let vm = FoodRecognitionViewModel(service: MockFoodRecognitionService(delayNanoseconds: 0))
        vm.startManual()
        vm.date = FoodTestFixtures.now
        vm.items = [FoodTestFixtures.draft()]
        vm.hasReviewed = true
        XCTAssertTrue(vm.canConfirm)
        let index = try XCTUnwrap(vm.items.indices.first)
        let itemID = vm.items[index].id
        @Bindable var bound = vm
        let calories: Binding<String> = $bound.items[index].caloriesText
        calories.wrappedValue = "175.125"
        XCTAssertEqual(vm.items[index].id, itemID)
        XCTAssertEqual(vm.items[index].caloriesText, "175.125")
        XCTAssertFalse(vm.hasReviewed)
        XCTAssertFalse(vm.canConfirm)
        assertFoodError(.invalidInput) { try vm.confirmedMeal() }
        vm.hasReviewed = true
        XCTAssertEqual(try vm.confirmedMeal().foods.first?.calories, 175.125)
    }

    @MainActor
    func testReplacingAddingRemovingAndChangingMealMetadataClearsReview() throws {
        let vm = FoodRecognitionViewModel(service: MockFoodRecognitionService(delayNanoseconds: 0))
        vm.startManual()
        vm.date = FoodTestFixtures.now
        vm.items = [FoodTestFixtures.draft()]
        vm.hasReviewed = true
        vm.items = [FoodTestFixtures.draft(name: "Replacement")]
        XCTAssertFalse(vm.hasReviewed)
        vm.hasReviewed = true
        vm.addItem()
        XCTAssertFalse(vm.hasReviewed)
        let addedID = try XCTUnwrap(vm.items.last?.id)
        vm.hasReviewed = true
        vm.removeItem(id: addedID)
        XCTAssertFalse(vm.hasReviewed)
        vm.hasReviewed = true
        vm.mealType = .dinner
        XCTAssertFalse(vm.hasReviewed)
        vm.hasReviewed = true
        vm.date = FoodTestFixtures.now.addingTimeInterval(-60)
        XCTAssertFalse(vm.hasReviewed)
    }

    @MainActor
    func testItemLimitAndSavedStatePreventFurtherAddOrDelete() throws {
        let vm = FoodRecognitionViewModel(service: MockFoodRecognitionService(delayNanoseconds: 0))
        vm.startManual()
        vm.date = FoodTestFixtures.now
        vm.items = (0..<FoodRecognitionResponse.maximumFoods).map { _ in FoodTestFixtures.draft() }
        let original = vm.items
        vm.addItem()
        XCTAssertEqual(vm.items, original)
        vm.hasReviewed = true
        let meal = try vm.confirmedMeal()
        vm.markSaved(meal)
        vm.addItem()
        vm.removeItem(id: try XCTUnwrap(original.first?.id))
        XCTAssertEqual(vm.items, original)
        XCTAssertTrue(vm.isSaved)
        XCTAssertFalse(vm.canConfirm)
        assertFoodError(.invalidInput) { try vm.confirmedMeal() }
    }

    @MainActor
    func testMockLoadConfirmAndMarkSavedStayInMemoryAndAppRejectsPersistence() throws {
        let (repository, app) = try makeStore()
        let vm = FoodRecognitionViewModel(service: app.foodRecognitionService)
        vm.loadMockExample()
        vm.date = FoodTestFixtures.now
        XCTAssertTrue(vm.hasDraft)
        XCTAssertEqual(vm.source, .mock)
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertTrue(vm.items.allSatisfy { $0.isAIRecognized == false })
        XCTAssertFalse(vm.canConfirm)
        assertFoodError(.invalidInput) { try vm.confirmedMeal() }
        XCTAssertEqual(repository.commitCount, 0)
        try assertMealCounts(repository, records: 0, items: 0)
        vm.hasReviewed = true
        let meal = try vm.confirmedMeal()
        XCTAssertEqual(meal.source, .mock)
        XCTAssertEqual(repository.commitCount, 0)
        vm.markSaved(meal)
        XCTAssertEqual(vm.demoResult, meal)
        XCTAssertTrue(vm.isSaved)
        XCTAssertFalse(vm.canConfirm)
        XCTAssertNil(vm.imageData)
        assertFoodError(.demoCannotPersist) { try app.saveConfirmedMeal(meal) }
        XCTAssertEqual(repository.commitCount, 0)
        XCTAssertTrue(app.data.meals.isEmpty)
        try assertMealCounts(repository, records: 0, items: 0)
    }

    @MainActor
    func testManualConfirmationDoesNotWriteUntilExplicitSaveAndSaveIsIdempotent() throws {
        let (repository, app) = try makeStore()
        let vm = FoodRecognitionViewModel(service: app.foodRecognitionService)
        vm.startManual()
        vm.date = FoodTestFixtures.now
        vm.mealType = .breakfast
        vm.items = [FoodTestFixtures.draft(), FoodTestFixtures.draft(name: "Unknown portion", calories: "")]
        assertFoodError(.invalidInput) { try vm.confirmedMeal() }
        XCTAssertEqual(repository.commitCount, 0)
        try assertMealCounts(repository, records: 0, items: 0)
        vm.hasReviewed = true
        let meal = try vm.confirmedMeal()
        XCTAssertEqual(meal.id, vm.draftID)
        XCTAssertEqual(repository.commitCount, 0)
        try assertMealCounts(repository, records: 0, items: 0)
        try app.saveConfirmedMeal(meal)
        vm.markSaved(meal)
        try app.saveConfirmedMeal(meal)
        XCTAssertEqual(repository.commitCount, 1)
        XCTAssertNil(vm.demoResult)
        XCTAssertTrue(vm.isSaved)
        XCTAssertEqual(app.data.meals.count, 1)
        try assertMealCounts(repository, records: 1, items: 2)
        let record = try XCTUnwrap(app.data.meals.first)
        XCTAssertEqual(record.id, meal.id)
        XCTAssertEqual(record.mealTypeRaw, "breakfast")
        XCTAssertEqual(record.sourceRaw, "manual")
        XCTAssertEqual(record.recordDate, FoodTestFixtures.now)
        XCTAssertEqual(record.confirmedAt, FoodTestFixtures.now)
        XCTAssertEqual(Set(record.items.map(\.id)), Set(meal.foods.map(\.id)))
        XCTAssertTrue(record.items.allSatisfy { $0.record?.id == record.id })
        XCTAssertEqual(record.knownCalories, 100)
        XCTAssertTrue(record.hasIncompleteCalories)
        let unknown = try XCTUnwrap(record.items.first { $0.name == "Unknown portion" })
        XCTAssertNil(unknown.weightGrams)
        XCTAssertNil(unknown.calories)
        XCTAssertNil(unknown.proteinGrams)
        XCTAssertNil(unknown.carbohydrateGrams)
        XCTAssertNil(unknown.fatGrams)
        XCTAssertNil(unknown.calorieLower)
        XCTAssertNil(unknown.calorieUpper)
        XCTAssertFalse(unknown.isAIRecognized)
    }

    @MainActor
    func testSavedMealInverseRelationshipsLoadBothDirectionsInFreshContexts() throws {
        let (repository, app) = try makeStore()
        let meals = [
            try FoodTestFixtures.confirm([FoodTestFixtures.draft(), FoodTestFixtures.draft(name: "Egg")]),
            try FoodTestFixtures.confirm([FoodTestFixtures.draft(name: "Soup")])
        ]
        for meal in meals { try app.saveConfirmedMeal(meal) }
        // Exercise each relationship as the first fetch in a separate, uncached context.
        for fetchItemsFirst in [false, true] {
            let context = ModelContext(repository.local.container)
            context.autosaveEnabled = false
            let records: [FoodRecord]
            let items: [FoodItem]
            if fetchItemsFirst {
                items = try context.fetch(FetchDescriptor<FoodItem>())
                records = try context.fetch(FetchDescriptor<FoodRecord>())
            } else {
                records = try context.fetch(FetchDescriptor<FoodRecord>())
                items = try context.fetch(FetchDescriptor<FoodItem>())
            }
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(items.count, 3)
            for meal in meals {
                let record = try XCTUnwrap(records.first { $0.id == meal.id })
                XCTAssertEqual(record.items.count, meal.foods.count)
                XCTAssertEqual(Set(record.items.map(\.id)), Set(meal.foods.map(\.id)))
                for value in meal.foods {
                    let item = try XCTUnwrap(items.first { $0.id == value.id })
                    let parent = try XCTUnwrap(item.record)
                    XCTAssertEqual(parent.id, meal.id)
                    XCTAssertEqual(parent.persistentModelID, record.persistentModelID)
                    let child = try XCTUnwrap(record.items.first { $0.id == item.id })
                    XCTAssertEqual(child.persistentModelID, item.persistentModelID)
                    XCTAssertEqual(child.record?.id, meal.id)
                    XCTAssertEqual(Set(parent.items.map(\.id)), Set(meal.foods.map(\.id)))
                }
            }
        }
    }

    @MainActor
    func testDeletingMealCascadeDeletesOwnedItemsButKeepsAnotherMeal() throws {
        let (repository, app) = try makeStore()
        let first = try FoodTestFixtures.confirm([FoodTestFixtures.draft(), FoodTestFixtures.draft(name: "Egg")])
        let second = try FoodTestFixtures.confirm([FoodTestFixtures.draft(name: "Soup")])
        try app.saveConfirmedMeal(first)
        try app.saveConfirmedMeal(second)
        try assertMealCounts(repository, records: 2, items: 3)
        let firstRecord = try XCTUnwrap(app.data.meals.first { $0.id == first.id })
        try app.deleteMeal(firstRecord)
        try assertMealCounts(repository, records: 1, items: 1)
        let remaining = try XCTUnwrap(app.data.meals.first)
        XCTAssertEqual(remaining.id, second.id)
        XCTAssertEqual(remaining.items.first?.name, "Soup")
        try app.deleteMeal(remaining)
        XCTAssertTrue(app.data.meals.isEmpty)
        try assertMealCounts(repository, records: 0, items: 0)
    }

    @MainActor
    func testAggregateIsInformationalAndSavedCaloriesRecalculateFromEditedItems() throws {
        let (repository, app) = try makeStore()
        let data = try FoodTestFixtures.responseData(overrides: [
            "totalEstimatedCalories": 999,
            "foods": [
                ["name": "Rice", "estimatedCalories": 100],
                ["name": "Unknown portion", "calorieRange": ["lower": 350, "upper": 650]]
            ]
        ])
        let response = try FoodRecognitionResponse.decode(data)
        XCTAssertEqual(response.totalEstimatedCalories, 999)
        var drafts = response.foods.map { EditableFoodItem(food: $0, isAIRecognized: true) }
        let index = try XCTUnwrap(drafts.firstIndex { $0.name == "Rice" })
        drafts[index].caloriesText = "125"
        let meal = try FoodTestFixtures.confirm(drafts, source: .remote)
        try app.saveConfirmedMeal(meal)
        let record = try XCTUnwrap(app.data.meals.first)
        XCTAssertEqual(record.knownCalories, 125)
        XCTAssertTrue(record.hasIncompleteCalories)
        let rangeItem = try XCTUnwrap(record.items.first { $0.name == "Unknown portion" })
        XCTAssertNil(rangeItem.calories)
        XCTAssertNil(rangeItem.weightGrams)
        XCTAssertNil(rangeItem.proteinGrams)
        XCTAssertNil(rangeItem.carbohydrateGrams)
        XCTAssertNil(rangeItem.fatGrams)
        XCTAssertEqual(rangeItem.calorieLower, 350)
        XCTAssertEqual(rangeItem.calorieUpper, 650)
        XCTAssertTrue(rangeItem.isAIRecognized)
        try assertMealCounts(repository, records: 1, items: 2)
    }

    @MainActor
    func testAppRechecksMealDateAgainstItsOwnClockBeforeWriting() throws {
        let (repository, app) = try makeStore()
        let future = FoodTestFixtures.now.addingTimeInterval(60)
        let meal = try ConfirmedFoodMeal.confirm(
            id: UUID(), mealType: .lunch, date: future, source: .manual,
            drafts: [FoodTestFixtures.draft()], userConfirmed: true, now: future
        )
        XCTAssertThrowsError(try app.saveConfirmedMeal(meal)) { error in
            XCTAssertTrue(error is InputError)
        }
        XCTAssertEqual(repository.commitCount, 0)
        try assertMealCounts(repository, records: 0, items: 0)
    }

    // MARK: - Real image preparation, no network

    func testBoundedPhotoTransferAcceptsExactlyTwentyMiB() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(repeating: 0xA5, count: 20 * 1024 * 1024)
        try bytes.write(to: url)
        let transferred = try FoodPhotoTransfer.readBounded(from: url)
        XCTAssertEqual(transferred.count, 20 * 1024 * 1024)
        XCTAssertEqual(transferred, bytes)
    }

    func testBoundedPhotoTransferRejectsTwentyMiBPlusOneByte() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0xA5, count: 20 * 1024 * 1024 + 1).write(to: url)
        assertFoodError(.imageTooLarge) { try FoodPhotoTransfer.readBounded(from: url) }
    }

    func testBoundedPhotoTransferRejectsEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        assertFoodError(.invalidImage) { try FoodPhotoTransfer.readBounded(from: url) }
    }

    @MainActor
    func testPNGAndJPEGProduceValidBoundedJPEGImages() async throws {
        for jpeg in [false, true] {
            let source = try FoodTestFixtures.imageData(jpeg: jpeg, size: CGSize(width: 2_400, height: 1_200))
            let prepared = try await FoodImageProcessor().prepare(source)
            try assertPreparedImage(prepared)
            XCTAssertEqual(prepared.width, 1_600)
            XCTAssertEqual(prepared.height, 800)
        }
    }

    @MainActor
    func testJPEGPreparationStripsActualGPSMetadata() async throws {
        let rendered = try FoodTestFixtures.imageData(jpeg: true)
        let sourceData = try FoodTestFixtures.addingGPS(to: rendered)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sourceData as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary])
        let prepared = try await FoodImageProcessor().prepare(sourceData)
        try assertPreparedImage(prepared)
    }

    @MainActor
    func testImagePreparationRejectsEmptyAndInvalidBytes() async {
        for data in [Data(), Data([0x00, 0xFF, 0x12, 0x34]), Data("not an image".utf8)] {
            do {
                _ = try await FoodImageProcessor().prepare(data)
                XCTFail("Invalid image bytes must not produce an upload")
            } catch {
                XCTAssertEqual(error as? FoodRecognitionError, .invalidImage)
            }
        }
    }

    @MainActor
    func testImagePreparationRejectsSourceOverByteLimitBeforeDecoding() async {
        let data = Data(repeating: 0, count: FoodImageProcessor.maximumSourceBytes + 1)
        do {
            _ = try await FoodImageProcessor().prepare(data)
            XCTFail("An oversized source must be rejected")
        } catch {
            XCTAssertEqual(error as? FoodRecognitionError, .imageTooLarge)
        }
    }

    // MARK: - Remote consent and stale completions, no network or timing assumptions

    private func remoteNotice() throws -> FoodUploadNotice {
        FoodUploadNotice(
            processorName: "Test processor", purpose: "Food estimation", retention: "Not retained",
            privacyPolicyURL: try XCTUnwrap(URL(string: "https://example.invalid/privacy"))
        )
    }

    @MainActor
    private func preparedRemoteViewModel(
        service: SuspendedFoodTestRemoteService
    ) async throws -> FoodRecognitionViewModel {
        let vm = FoodRecognitionViewModel(service: service)
        let selection = vm.beginPhotoSelection()
        let data = try FoodTestFixtures.imageData(jpeg: false)
        await vm.preparePhoto(data, selectionID: selection)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isPreparing)
        XCTAssertTrue(vm.canRecognize)
        XCTAssertEqual(vm.mode, .remote)
        return vm
    }

    @MainActor
    func testRemoteCallsRequireBothUploadNoticeAndExplicitConsent() async throws {
        let notice = try remoteNotice()
        for hasNotice in [false, true] {
            for hasConsent in [false, true] {
                let service = SuspendedFoodTestRemoteService(notice: hasNotice ? notice : nil)
                // If a gate regresses, fail with a call-count assertion rather than hanging.
                await service.resolve(call: 0, with: .failure(.offline))
                let vm = try await preparedRemoteViewModel(service: service)
                vm.uploadConsent = hasConsent
                await vm.recognize()
                let calls = await service.callCount
                let allowed = hasNotice && hasConsent
                XCTAssertEqual(calls, allowed ? 1 : 0, "notice=\(hasNotice), consent=\(hasConsent)")
                XCTAssertEqual(vm.error, allowed ? .offline : .consentRequired)
                XCTAssertFalse(vm.isRecognizing)
                XCTAssertFalse(vm.hasDraft)
                XCTAssertTrue(vm.items.isEmpty)
            }
        }
    }

    @MainActor
    private func assertRemoteCompletionResetsConsent(
        failure: FoodRecognitionError?, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let response = try FoodRecognitionResponse.decode(Data(MockFoodRecognitionService.sampleJSON.utf8))
        let entered = expectation(description: "Remote request suspended")
        let service = SuspendedFoodTestRemoteService(notice: try remoteNotice(), entered: [entered])
        let vm = try await preparedRemoteViewModel(service: service)
        vm.uploadConsent = true
        let request = Task { @MainActor in await vm.recognize() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(vm.isRecognizing, file: file, line: line)
        XCTAssertTrue(vm.uploadConsent, file: file, line: line)
        if let failure {
            await service.resolve(call: 0, with: .failure(failure))
        } else {
            await service.resolve(call: 0, with: .success(response))
        }
        await request.value
        XCTAssertFalse(vm.isRecognizing, file: file, line: line)
        XCTAssertFalse(vm.uploadConsent, file: file, line: line)
        XCTAssertEqual(vm.error, failure, file: file, line: line)
        XCTAssertFalse(vm.hasReviewed, file: file, line: line)
        if failure == nil {
            XCTAssertTrue(vm.hasDraft, file: file, line: line)
            XCTAssertEqual(vm.source, .remote, file: file, line: line)
            XCTAssertEqual(vm.items.map(\.name), response.foods.map(\.name), file: file, line: line)
            XCTAssertTrue(vm.items.allSatisfy(\.isAIRecognized), file: file, line: line)
        } else {
            XCTAssertFalse(vm.hasDraft, file: file, line: line)
            XCTAssertTrue(vm.items.isEmpty, file: file, line: line)
        }
        XCTAssertTrue(vm.canRecognize, file: file, line: line)
        // Completion consumes consent; another click must not issue another upload.
        await service.resolve(call: 1, with: .failure(.offline))
        await vm.recognize()
        let calls = await service.callCount
        XCTAssertEqual(calls, 1, file: file, line: line)
        XCTAssertEqual(vm.error, .consentRequired, file: file, line: line)
    }

    @MainActor
    func testRemoteSuccessResetsUploadConsentAndRequiresConsentAgain() async throws {
        try await assertRemoteCompletionResetsConsent(failure: nil)
    }

    @MainActor
    func testRemoteFailureResetsUploadConsentAndRequiresConsentAgain() async throws {
        try await assertRemoteCompletionResetsConsent(failure: .offline)
    }

    private enum RemoteReplacement { case reset, manual, selection }

    @MainActor
    private func assertStaleRemoteCompletionIsIgnored(
        after replacement: RemoteReplacement, failure: FoodRecognitionError?,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let response = try FoodRecognitionResponse.decode(Data(MockFoodRecognitionService.sampleJSON.utf8))
        // Without cancellation, success exercises the generation guard directly. With
        // cancellation, the service still returns/throws only when explicitly resumed.
        for cancelRequest in [false, true] {
            let entered = expectation(description: "Old request suspended; cancelled=\(cancelRequest)")
            let service = SuspendedFoodTestRemoteService(notice: try remoteNotice(), entered: [entered])
            let vm = try await preparedRemoteViewModel(service: service)
            vm.uploadConsent = true
            let request = Task { @MainActor in await vm.recognize() }
            await fulfillment(of: [entered], timeout: 5)
            let calls = await service.callCount
            XCTAssertEqual(calls, 1, file: file, line: line)
            XCTAssertTrue(vm.isRecognizing, file: file, line: line)
            if cancelRequest { request.cancel() }
            switch replacement {
            case .reset:
                vm.reset()
                XCTAssertFalse(vm.hasDraft, file: file, line: line)
                XCTAssertNil(vm.imageData, file: file, line: line)
            case .manual:
                vm.startManual()
                vm.date = FoodTestFixtures.now
                vm.mealType = .breakfast
                vm.items = [FoodTestFixtures.draft(name: "New manual meal", calories: "321")]
                vm.hasReviewed = true
                XCTAssertTrue(vm.canConfirm, file: file, line: line)
            case .selection:
                _ = vm.beginPhotoSelection()
                XCTAssertTrue(vm.isPreparing, file: file, line: line)
                XCTAssertNil(vm.imageData, file: file, line: line)
            }
            XCTAssertFalse(vm.uploadConsent, file: file, line: line)
            let replacementState = FoodTestWorkflowState(vm)
            if let failure {
                await service.resolve(call: 0, with: .failure(failure))
            } else {
                await service.resolve(call: 0, with: .success(response))
            }
            await request.value
            XCTAssertEqual(FoodTestWorkflowState(vm), replacementState,
                           "cancelled=\(cancelRequest)", file: file, line: line)
        }
    }

    @MainActor
    func testOldRemoteSuccessCannotChangeStateAfterReset() async throws {
        try await assertStaleRemoteCompletionIsIgnored(after: .reset, failure: nil)
    }

    @MainActor
    func testOldRemoteErrorCannotChangeStateAfterReset() async throws {
        try await assertStaleRemoteCompletionIsIgnored(after: .reset, failure: .offline)
    }

    @MainActor
    func testOldRemoteSuccessCannotChangeStateAfterManualEntry() async throws {
        try await assertStaleRemoteCompletionIsIgnored(after: .manual, failure: nil)
    }

    @MainActor
    func testOldRemoteErrorCannotChangeStateAfterManualEntry() async throws {
        try await assertStaleRemoteCompletionIsIgnored(after: .manual, failure: .offline)
    }

    @MainActor
    func testOldRemoteSuccessCannotChangeStateAfterNewPhotoSelection() async throws {
        try await assertStaleRemoteCompletionIsIgnored(after: .selection, failure: nil)
    }

    @MainActor
    func testOldRemoteErrorCannotChangeStateAfterNewPhotoSelection() async throws {
        try await assertStaleRemoteCompletionIsIgnored(after: .selection, failure: .offline)
    }

    @MainActor
    func testOldRemoteCompletionCannotClearNewRequestBusyStateOrConsent() async throws {
        let response = try FoodRecognitionResponse.decode(Data(MockFoodRecognitionService.sampleJSON.utf8))
        let data = try FoodTestFixtures.imageData(jpeg: true)
        let outcomes: [Result<FoodRecognitionResponse, FoodRecognitionError>] = [
            .success(response), .failure(.offline)
        ]
        for outcome in outcomes {
            for cancelOldRequest in [false, true] {
                let oldEntered = expectation(description: "Old upload suspended")
                let newEntered = expectation(description: "New upload suspended")
                let service = SuspendedFoodTestRemoteService(
                    notice: try remoteNotice(), entered: [oldEntered, newEntered]
                )
                let vm = try await preparedRemoteViewModel(service: service)
                vm.uploadConsent = true
                let oldRequest = Task { @MainActor in await vm.recognize() }
                await fulfillment(of: [oldEntered], timeout: 5)
                if cancelOldRequest { oldRequest.cancel() }
                let selection = vm.beginPhotoSelection()
                XCTAssertFalse(vm.uploadConsent)
                await vm.preparePhoto(data, selectionID: selection)
                XCTAssertTrue(vm.canRecognize)
                vm.uploadConsent = true
                let newRequest = Task { @MainActor in await vm.recognize() }
                await fulfillment(of: [newEntered], timeout: 5)
                let calls = await service.callCount
                XCTAssertEqual(calls, 2)
                XCTAssertTrue(vm.isRecognizing)
                XCTAssertTrue(vm.uploadConsent)
                let newState = FoodTestWorkflowState(vm)
                await service.resolve(call: 0, with: outcome)
                await oldRequest.value
                XCTAssertEqual(FoodTestWorkflowState(vm), newState)
                // Drain the newer task too; no continuation or unstructured task is abandoned.
                await service.resolve(call: 1, with: .success(response))
                await newRequest.value
                XCTAssertFalse(vm.isRecognizing)
                XCTAssertFalse(vm.uploadConsent)
                XCTAssertNil(vm.error)
                XCTAssertTrue(vm.hasDraft)
                XCTAssertEqual(vm.source, .remote)
                XCTAssertEqual(vm.items.map(\.name), response.foods.map(\.name))
            }
        }
    }

    // MARK: - Offline mock scenarios and workflow

    @MainActor
    func testMockSuccessAndRangeOnlyScenariosUseTheRealDecoder() async throws {
        let source = try FoodTestFixtures.imageData(jpeg: false)
        let image = try await FoodImageProcessor().prepare(source)
        let scenarios: [(MockFoodRecognitionService.Scenario, String)] = [
            (.success, MockFoodRecognitionService.sampleJSON), (.rangeOnly, MockFoodRecognitionService.rangeJSON)
        ]
        for (scenario, json) in scenarios {
            let service = MockFoodRecognitionService(scenario: scenario, delayNanoseconds: 0)
            XCTAssertEqual(service.mode, .mock)
            XCTAssertNil(service.uploadNotice)
            let response = try await service.recognize(image: image, requestID: UUID())
            XCTAssertEqual(response, try FoodRecognitionResponse.decode(Data(json.utf8)))
        }
    }

    @MainActor
    func testMockFailureScenariosReturnTypedErrors() async throws {
        let source = try FoodTestFixtures.imageData(jpeg: true)
        let image = try await FoodImageProcessor().prepare(source)
        let scenarios: [(MockFoodRecognitionService.Scenario, FoodRecognitionError)] = [
            (.offline, .offline), (.timeout, .timeout), (.unrecognized, .unrecognized)
        ]
        for (scenario, expected) in scenarios {
            do {
                _ = try await MockFoodRecognitionService(scenario: scenario, delayNanoseconds: 0)
                    .recognize(image: image, requestID: UUID())
                XCTFail("Mock scenario \(scenario) should throw")
            } catch {
                XCTAssertEqual(error as? FoodRecognitionError, expected)
            }
        }
    }

    @MainActor
    func testMockRecognitionWorkflowPreparesPhotoWithoutWritingFoodRecords() async throws {
        let (repository, app) = try makeStore()
        let vm = FoodRecognitionViewModel(service: app.foodRecognitionService)
        let selection = vm.beginPhotoSelection()
        XCTAssertTrue(vm.isPreparing)
        XCTAssertFalse(vm.canRecognize)
        let source = try FoodTestFixtures.imageData(jpeg: false)
        await vm.preparePhoto(source, selectionID: selection)
        XCTAssertFalse(vm.isPreparing)
        XCTAssertTrue(vm.canRecognize)
        XCTAssertNotNil(vm.imageData)
        await vm.recognize()
        vm.date = FoodTestFixtures.now
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isRecognizing)
        XCTAssertTrue(vm.hasDraft)
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertFalse(vm.hasReviewed)
        XCTAssertEqual(vm.source, .mock)
        XCTAssertEqual(repository.commitCount, 0)
        try assertMealCounts(repository, records: 0, items: 0)
        vm.hasReviewed = true
        let meal = try vm.confirmedMeal()
        vm.markSaved(meal)
        XCTAssertEqual(vm.demoResult, meal)
        XCTAssertNil(vm.imageData)
        XCTAssertFalse(vm.canRecognize)
        XCTAssertFalse(vm.uploadConsent)
        XCTAssertEqual(repository.commitCount, 0)
        try assertMealCounts(repository, records: 0, items: 0)
    }

    @MainActor
    func testMockFailureClearsBusyStateAndDoesNotExposeConfirmableDraft() async throws {
        let vm = FoodRecognitionViewModel(service: MockFoodRecognitionService(scenario: .offline, delayNanoseconds: 0))
        let selection = vm.beginPhotoSelection()
        let source = try FoodTestFixtures.imageData(jpeg: true)
        await vm.preparePhoto(source, selectionID: selection)
        vm.uploadConsent = true
        await vm.recognize()
        XCTAssertEqual(vm.error, .offline)
        XCTAssertFalse(vm.isRecognizing)
        XCTAssertFalse(vm.hasDraft)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertFalse(vm.canConfirm)
        XCTAssertFalse(vm.uploadConsent)
        XCTAssertTrue(vm.canRecognize)
        assertFoodError(.invalidInput) { try vm.confirmedMeal() }
    }

    @MainActor
    func testStalePhotoSelectionCannotReplaceManualDraft() async throws {
        let vm = FoodRecognitionViewModel(service: MockFoodRecognitionService(delayNanoseconds: 0))
        let selection = vm.beginPhotoSelection()
        vm.startManual()
        vm.date = FoodTestFixtures.now
        vm.items = [FoodTestFixtures.draft()]
        let draftID = vm.draftID
        let source = try FoodTestFixtures.imageData(jpeg: false)
        await vm.preparePhoto(source, selectionID: selection)
        vm.photoSelectionFailed(selection)
        XCTAssertEqual(vm.draftID, draftID)
        XCTAssertEqual(vm.source, .manual)
        XCTAssertEqual(vm.items.first?.name, "Rice")
        XCTAssertTrue(vm.hasDraft)
        XCTAssertFalse(vm.isPreparing)
        XCTAssertNil(vm.imageData)
        XCTAssertNil(vm.error)
    }
}