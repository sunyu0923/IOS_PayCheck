// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPetTests/RemoteFoodRecognitionServiceTests.swift
// Purpose: Offline request, error, retry, cancellation, and safety tests for the food proxy client.
// Dependencies: XCTest, Foundation, UIKit, @testable GoalPet; iOS 17+, Swift 5. No real network.

import Foundation
import UIKit
import XCTest
@testable import GoalPet

private actor StubFoodHTTPTransport: FoodHTTPTransport {
    enum Outcome: Sendable {
        case response(FoodHTTPResponse)
        case failure(Error)
    }

    struct Call: Sendable {
        let request: URLRequest
        let maximumResponseBytes: Int
    }

    private var outcomes: [Outcome]
    private(set) var calls: [Call] = []
    private let firstResponsePaused: (@Sendable () -> Void)?
    private var firstResponseContinuation: CheckedContinuation<Void, Never>?
    private var firstResponseReleased = false

    init(
        _ outcomes: [Outcome],
        firstResponsePaused: (@Sendable () -> Void)? = nil
    ) {
        self.outcomes = outcomes
        self.firstResponsePaused = firstResponsePaused
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> FoodHTTPResponse {
        calls.append(Call(request: request, maximumResponseBytes: maximumResponseBytes))
        guard !outcomes.isEmpty else {
            // Record unexpected calls, then fail locally; never fall back to URLSession.
            throw FoodRecognitionError.transport
        }
        let outcome = outcomes.removeFirst()
        if calls.count == 1, !firstResponseReleased, let firstResponsePaused {
            await withCheckedContinuation { continuation in
                firstResponseContinuation = continuation
                firstResponsePaused()
            }
        }
        switch outcome {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    func releaseFirstResponse() {
        firstResponseReleased = true
        firstResponseContinuation?.resume()
        firstResponseContinuation = nil
    }
}

final class RemoteFoodRecognitionServiceTests: XCTestCase {
    private static let validJSON = Data("""
    {"mealType":"lunch","foods":[{"name":"Rice","estimatedCalories":130}],
     "totalEstimatedCalories":130,"disclaimer":"Test estimate only"}
    """.utf8)

    private static func response(
        status: Int = 200,
        data: Data = validJSON,
        mimeType: String? = "application/json"
    ) -> FoodHTTPResponse {
        FoodHTTPResponse(data: data, statusCode: status, mimeType: mimeType)
    }

    private func configuration(
        endpoint: String = "https://proxy.example.test/v1/food/recognize",
        allowsIdempotentRetry: Bool = false,
        maximumRetryCount: Int = 1,
        timeout: TimeInterval = 30
    ) throws -> RemoteFoodRecognitionService.Configuration {
        let url = try XCTUnwrap(URL(string: endpoint))
        let privacyURL = try XCTUnwrap(URL(string: "https://proxy.example.test/privacy"))
        return RemoteFoodRecognitionService.Configuration(
            endpoint: url,
            uploadNotice: FoodUploadNotice(
                processorName: "Test food proxy",
                purpose: "Estimate food nutrition for this test upload",
                retention: "Not retained",
                privacyPolicyURL: privacyURL
            ),
            timeout: timeout,
            allowsIdempotentRetry: allowsIdempotentRetry,
            maximumRetryCount: maximumRetryCount
        )
    }

    private func service(
        transport: StubFoodHTTPTransport,
        allowsIdempotentRetry: Bool = false,
        maximumRetryCount: Int = 1,
        accessToken: @escaping @Sendable () async throws -> String = { "test-session" }
    ) throws -> RemoteFoodRecognitionService {
        try RemoteFoodRecognitionService(
            configuration: configuration(
                allowsIdempotentRetry: allowsIdempotentRetry,
                maximumRetryCount: maximumRetryCount
            ),
            accessToken: accessToken,
            transport: transport
        )
    }

    @MainActor
    private static func minimalJPEG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    private func preparedImage() async throws -> PreparedFoodImage {
        let jpeg = try await Self.minimalJPEG()
        return try await FoodImageProcessor().prepare(jpeg)
    }

    private func assertRecognitionError(
        _ expected: FoodRecognitionError,
        service: RemoteFoodRecognitionService,
        image: PreparedFoodImage,
        context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.recognize(image: image, requestID: UUID())
            XCTFail("Expected \(expected.code). \(context)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? FoodRecognitionError, expected, context, file: file, line: line)
        }
    }

    func testPOSTUsesPreparedJPEGAndSessionAuthorizationWithoutVendorKeys() async throws {
        let transport = StubFoodHTTPTransport([.response(Self.response())])
        let configuration = try configuration()
        let service = try RemoteFoodRecognitionService(
            configuration: configuration,
            accessToken: { "test-session" },
            transport: transport
        )
        let image = try await preparedImage()
        let requestID = UUID()
        let result = try await service.recognize(image: image, requestID: requestID)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        let request = call.request
        XCTAssertEqual(service.mode, .remote)
        XCTAssertEqual(service.uploadNotice, configuration.uploadNotice)
        XCTAssertEqual(request.url, configuration.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), requestID.uuidString)
        let headerNames = Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertEqual(headerNames, Set(["content-type", "accept", "authorization", "idempotency-key"]))
        for header in ["api-key", "x-api-key", "Ocp-Apim-Subscription-Key", "OpenAI-Organization"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header))
        }
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(call.maximumResponseBytes, FoodRecognitionResponse.maximumResponseBytes)
        XCTAssertEqual(call.maximumResponseBytes, 256 * 1024)

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: String])
        XCTAssertEqual(Set(body.keys), Set(["requestID", "imageBase64", "mimeType"]))
        XCTAssertEqual(body["requestID"], requestID.uuidString)
        XCTAssertEqual(body["mimeType"], "image/jpeg")
        let base64 = try XCTUnwrap(body["imageBase64"])
        XCTAssertEqual(Data(base64Encoded: base64), image.jpegData)
        XCTAssertEqual(result, try FoodRecognitionResponse.decode(Self.validJSON))
    }

    func testHTTPStatusMapping() async throws {
        let image = try await preparedImage()
        let cases: [(Int, FoodRecognitionError)] = [
            (401, .unauthorized), (403, .unauthorized), (413, .imageTooLarge),
            (422, .unrecognized), (429, .rateLimited), (408, .timeout),
            (504, .timeout), (503, .serverUnavailable)
        ]
        for (status, expected) in cases {
            let transport = StubFoodHTTPTransport([.response(Self.response(status: status))])
            let service = try service(transport: transport)
            await assertRecognitionError(expected, service: service, image: image, context: "HTTP \(status)")
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1, "HTTP \(status)")
        }
    }

    func testTransportErrorsMapToSafeDomainErrors() async throws {
        let image = try await preparedImage()
        let cases: [(Error, FoodRecognitionError)] = [
            (URLError(.notConnectedToInternet), .offline),
            (URLError(.networkConnectionLost), .offline),
            (URLError(.dataNotAllowed), .offline),
            (URLError(.timedOut), .timeout),
            (URLError(.cancelled), .cancelled),
            (CancellationError(), .cancelled),
            (URLError(.secureConnectionFailed), .transport),
            (NSError(domain: "StubOnly", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Untrusted transport details"
            ]), .transport)
        ]
        for (error, expected) in cases {
            let transport = StubFoodHTTPTransport([.failure(error), .response(Self.response())])
            let service = try service(transport: transport)
            await assertRecognitionError(expected, service: service, image: image)
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testDefaultConfigurationDoesNotRetryTransientHTTPResponses() async throws {
        let image = try await preparedImage()
        for status in [502, 503, 504] {
            let transport = StubFoodHTTPTransport([
                .response(Self.response(status: status)), .response(Self.response())
            ])
            let service = try service(transport: transport)
            await assertRecognitionError(
                status == 504 ? .timeout : .serverUnavailable,
                service: service, image: image, context: "HTTP \(status)"
            )
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testEnabledRetryAfter503SucceedsWithSameIdempotencyKeyAndBody() async throws {
        let transport = StubFoodHTTPTransport([
            .response(Self.response(status: 503)), .response(Self.response())
        ])
        let service = try service(transport: transport, allowsIdempotentRetry: true)
        let image = try await preparedImage()
        let requestID = UUID()
        let result = try await service.recognize(image: image, requestID: requestID)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(result, try FoodRecognitionResponse.decode(Self.validJSON))
        XCTAssertEqual(calls.map { $0.request.value(forHTTPHeaderField: "Idempotency-Key") },
                       [requestID.uuidString, requestID.uuidString])
        let first = try XCTUnwrap(calls.first)
        XCTAssertNotNil(first.request.httpBody)
        for call in calls {
            XCTAssertEqual(call.request.httpBody, first.request.httpBody)
            XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-session")
            XCTAssertEqual(call.maximumResponseBytes, FoodRecognitionResponse.maximumResponseBytes)
        }
    }

    func testMaximumOneRetryStopsAfterTwo503Responses() async throws {
        let transport = StubFoodHTTPTransport([
            .response(Self.response(status: 503)), .response(Self.response(status: 503)),
            .response(Self.response())
        ])
        let service = try service(transport: transport, allowsIdempotentRetry: true, maximumRetryCount: 1)
        let image = try await preparedImage()
        await assertRecognitionError(.serverUnavailable, service: service, image: image)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testZeroRetryLimitDisablesEvenExplicitlyEnabledRetries() async throws {
        let transport = StubFoodHTTPTransport([
            .response(Self.response(status: 503)), .response(Self.response())
        ])
        let service = try service(transport: transport, allowsIdempotentRetry: true, maximumRetryCount: 0)
        let image = try await preparedImage()
        await assertRecognitionError(.serverUnavailable, service: service, image: image)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testEnabledRetryDoesNotRetry429408OrTransportTimeoutAndOfflineErrors() async throws {
        let image = try await preparedImage()
        let cases: [(StubFoodHTTPTransport.Outcome, FoodRecognitionError)] = [
            (.response(Self.response(status: 429)), .rateLimited),
            (.response(Self.response(status: 408)), .timeout),
            (.failure(URLError(.timedOut)), .timeout),
            (.failure(URLError(.notConnectedToInternet)), .offline)
        ]
        for (outcome, expected) in cases {
            let transport = StubFoodHTTPTransport([outcome, .response(Self.response())])
            let service = try service(transport: transport, allowsIdempotentRetry: true, maximumRetryCount: 1)
            await assertRecognitionError(expected, service: service, image: image)
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testCancellationDuringFirstRequestPreventsFurtherCalls() async throws {
        let paused = expectation(description: "First stub response is suspended")
        let transport = StubFoodHTTPTransport([
            .response(Self.response(status: 503)), .response(Self.response())
        ], firstResponsePaused: { paused.fulfill() })
        let service = try service(transport: transport, allowsIdempotentRetry: true)
        let image = try await preparedImage()
        let task = Task {
            try await service.recognize(image: image, requestID: UUID())
        }
        await fulfillment(of: [paused], timeout: 5)
        task.cancel()
        // The stub deliberately returns a response despite cancellation, exercising
        // the client's own cancellation check rather than relying on URLSession.
        await transport.releaseFirstResponse()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? FoodRecognitionError, .cancelled)
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testMalformedHTMLContentTypeAndEmptyResponsesAreRejected() async throws {
        let image = try await preparedImage()
        let html = Data("<html><body>Not JSON</body></html>".utf8)
        let responses = [
            Self.response(data: html, mimeType: "text/html"),
            Self.response(data: html),
            Self.response(mimeType: "text/html"),
            Self.response(mimeType: nil),
            Self.response(mimeType: ""),
            Self.response(data: Data("{".utf8)),
            Self.response(data: Data()),
            Self.response(status: 204, data: Data())
        ]
        for (index, response) in responses.enumerated() {
            let transport = StubFoodHTTPTransport([.response(response), .response(Self.response())])
            let service = try service(transport: transport, allowsIdempotentRetry: true)
            await assertRecognitionError(
                .malformedResponse, service: service, image: image, context: "Response case \(index)"
            )
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testOversizedResponseIsRejectedBeforeDecodeOrRetry() async throws {
        let image = try await preparedImage()
        let oversized = Data(repeating: 0x20, count: FoodRecognitionResponse.maximumResponseBytes + 1)
        for status in [200, 503] {
            let transport = StubFoodHTTPTransport([
                .response(Self.response(status: status, data: oversized)), .response(Self.response())
            ])
            let service = try service(transport: transport, allowsIdempotentRetry: true)
            await assertRecognitionError(.responseTooLarge, service: service, image: image)
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.maximumResponseBytes, 256 * 1024)
        }
    }

    func testResponseExactlyAtByteLimitAndJSONCharsetAreAccepted() async throws {
        var data = Self.validJSON
        data.append(Data(repeating: 0x20, count: FoodRecognitionResponse.maximumResponseBytes - data.count))
        let transport = StubFoodHTTPTransport([
            .response(Self.response(data: data, mimeType: "Application/JSON; charset=utf-8"))
        ])
        let service = try service(transport: transport)
        let image = try await preparedImage()
        let result = try await service.recognize(image: image, requestID: UUID())
        XCTAssertEqual(result, try FoodRecognitionResponse.decode(Self.validJSON))
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testConfigurationRejectsUnsafeEndpointsWithoutSending() async throws {
        let transport = StubFoodHTTPTransport([])
        for endpoint in [
            "http://proxy.example.test/v1/food/recognize",
            "https://user@proxy.example.test/v1/food/recognize",
            "https://user:password@proxy.example.test/v1/food/recognize",
            "https://proxy.example.test/v1/food/recognize?debug=1",
            "https://proxy.example.test/v1/food/recognize#fragment",
            "https://proxy.example.test",
            "https://proxy.example.test/"
        ] {
            let configuration = try configuration(endpoint: endpoint)
            XCTAssertThrowsError(try RemoteFoodRecognitionService(
                configuration: configuration, accessToken: { "test-session" }, transport: transport
            ), endpoint) { error in
                XCTAssertEqual(error as? FoodRecognitionError, .invalidConfiguration, endpoint)
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testConfigurationEnforcesRetryAndTimeoutLimitsWithoutSending() async throws {
        let transport = StubFoodHTTPTransport([])
        var configurations: [RemoteFoodRecognitionService.Configuration] = []
        for retryCount in [-1, 2] {
            configurations.append(try configuration(allowsIdempotentRetry: true, maximumRetryCount: retryCount))
        }
        let invalidTimeouts: [TimeInterval] = [0, -1, 61, .infinity, .nan]
        for timeout in invalidTimeouts {
            configurations.append(try configuration(timeout: timeout))
        }
        for configuration in configurations {
            XCTAssertThrowsError(try RemoteFoodRecognitionService(
                configuration: configuration, accessToken: { "test-session" }, transport: transport
            )) { error in
                XCTAssertEqual(error as? FoodRecognitionError, .invalidConfiguration)
            }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testMissingTokenIsUnauthorizedWithoutSending() async throws {
        let transport = StubFoodHTTPTransport([.response(Self.response())])
        let service = try service(transport: transport, accessToken: { "" })
        let image = try await preparedImage()
        await assertRecognitionError(.unauthorized, service: service, image: image)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testCRLFTokenIsUnauthorizedWithoutSending() async throws {
        let transport = StubFoodHTTPTransport([.response(Self.response())])
        let service = try service(
            transport: transport,
            accessToken: { "test-session\r\nX-Injected: not-a-secret" }
        )
        let image = try await preparedImage()
        await assertRecognitionError(.unauthorized, service: service, image: image)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 0)
    }
}