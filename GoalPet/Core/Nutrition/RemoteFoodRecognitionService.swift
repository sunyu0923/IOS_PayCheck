// File: C:/Users/YSun14/OneDrive - Rockwell Automation, Inc/Desktop/WorkProject/IOS_PayCheck/GoalPet/Core/Nutrition/RemoteFoodRecognitionService.swift
// Purpose: HTTPS backend-proxy client; ephemeral bounded transport, no redirects and opt-in idempotent retry.
// Dependencies: Foundation, FoodRecognitionContract, PreparedFoodImage. Session tokens are injected, never vendor API keys.
import Foundation

struct FoodHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let mimeType: String?
}

/// Implementations must enforce the response limit and must never follow redirects.
protocol FoodHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> FoodHTTPResponse
}

struct URLSessionFoodHTTPTransport: FoodHTTPTransport {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> FoodHTTPResponse {
        guard maximumResponseBytes > 0,
              request.timeoutInterval.isFinite,
              request.timeoutInterval > 0, request.timeoutInterval <= 60 else {
            throw FoodRecognitionError.invalidConfiguration
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval

        // A separate session keeps cancellation and teardown local to this upload.
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            return try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: request)
                try Task.checkCancellation()
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw FoodRecognitionError.malformedResponse
                }
                guard !(300...399).contains(httpResponse.statusCode) else {
                    throw FoodRecognitionError.malformedResponse
                }
                guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
                    throw FoodRecognitionError.responseTooLarge
                }

                var data = Data()
                // Do not trust Content-Length: unknown, chunked and decompressed bodies
                // must also be bounded. Check BEFORE appending the next byte.
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maximumResponseBytes else {
                        throw FoodRecognitionError.responseTooLarge
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return FoodHTTPResponse(
                    data: data,
                    statusCode: httpResponse.statusCode,
                    mimeType: httpResponse.mimeType
                )
            }, onCancel: {
                session.invalidateAndCancel()
            })
        } catch {
            if Task.isCancelled { throw FoodRecognitionError.cancelled }
            throw FoodRecognitionError.safe(error)
        }
    }

    // Stateless; URLSession may call this delegate from its own queue.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            // Even same-origin redirects are denied: never forward the image or token.
            completionHandler(nil)
        }
    }
}

struct RemoteFoodRecognitionService: FoodRecognitionService, Sendable {
    struct Configuration: Sendable {
        /// Developer-supplied complete backend route, not a user-entered URL or AI endpoint.
        let endpoint: URL
        let uploadNotice: FoodUploadNotice
        let timeout: TimeInterval
        /// Enable only when the backend guarantees deduplication by Idempotency-Key.
        let allowsIdempotentRetry: Bool
        let maximumRetryCount: Int

        init(
            endpoint: URL,
            uploadNotice: FoodUploadNotice,
            timeout: TimeInterval = 30,
            allowsIdempotentRetry: Bool = false,
            maximumRetryCount: Int = 1
        ) {
            self.endpoint = endpoint
            self.uploadNotice = uploadNotice
            self.timeout = timeout
            self.allowsIdempotentRetry = allowsIdempotentRetry
            self.maximumRetryCount = maximumRetryCount
        }

        fileprivate func validate() throws {
            guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
                  endpoint.baseURL == nil,
                  components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.path.hasPrefix("/"),
                  !components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines)).isEmpty,
                  timeout.isFinite, timeout > 0, timeout <= 60,
                  (0...1).contains(maximumRetryCount) else {
                throw FoodRecognitionError.invalidConfiguration
            }

            let noticeFields = [uploadNotice.processorName, uploadNotice.purpose, uploadNotice.retention]
            guard noticeFields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  let privacy = URLComponents(url: uploadNotice.privacyPolicyURL, resolvingAgainstBaseURL: false),
                  uploadNotice.privacyPolicyURL.baseURL == nil,
                  privacy.scheme?.lowercased() == "https",
                  let privacyHost = privacy.host, !privacyHost.isEmpty,
                  privacy.user == nil, privacy.password == nil else {
                throw FoodRecognitionError.invalidConfiguration
            }
        }
    }

    private struct RequestBody: Codable {
        let requestID: String
        let imageBase64: String
        let mimeType: String
    }

    private static let maximumImageBytes = 4 * 1024 * 1024
    private let configuration: Configuration
    private let accessToken: @Sendable () async throws -> String
    private let transport: any FoodHTTPTransport

    var mode: FoodRecognitionMode { .remote }
    var uploadNotice: FoodUploadNotice? { configuration.uploadNotice }

    /// The provider supplies a short-lived app-session bearer token, never an AI API key.
    /// The caller must obtain explicit upload consent before calling recognize.
    init(
        configuration: Configuration,
        accessToken: @escaping @Sendable () async throws -> String,
        transport: any FoodHTTPTransport = URLSessionFoodHTTPTransport()
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.accessToken = accessToken
        self.transport = transport
    }

    func recognize(image: PreparedFoodImage, requestID: UUID) async throws -> FoodRecognitionResponse {
        do {
            try Task.checkCancellation()
            guard image.jpegData.count <= Self.maximumImageBytes else {
                throw FoodRecognitionError.imageTooLarge
            }
            guard !image.jpegData.isEmpty, image.width > 0, image.height > 0 else {
                throw FoodRecognitionError.invalidImage
            }

            let identifier = requestID.uuidString
            let body = try JSONEncoder().encode(RequestBody(
                requestID: identifier,
                imageBase64: image.jpegData.base64EncodedString(),
                mimeType: "image/jpeg"
            ))
            let retryCount = configuration.allowsIdempotentRetry ? configuration.maximumRetryCount : 0

            for attempt in 0...retryCount {
                try Task.checkCancellation()
                let token = try await accessToken()
                try Task.checkCancellation()
                // RFC 6750 bearer characters only; never allow header injection or whitespace.
                let allowedTokenCharacters = CharacterSet(
                    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/="
                )
                guard !token.isEmpty,
                      token.unicodeScalars.allSatisfy({ allowedTokenCharacters.contains($0) }) else {
                    throw FoodRecognitionError.unauthorized
                }

                var request = URLRequest(
                    url: configuration.endpoint,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: configuration.timeout
                )
                request.httpMethod = "POST"
                request.httpShouldHandleCookies = false
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(identifier, forHTTPHeaderField: "Idempotency-Key")
                request.httpBody = body

                let response = try await transport.send(
                    request, maximumResponseBytes: FoodRecognitionResponse.maximumResponseBytes
                )
                try Task.checkCancellation()
                // Also enforce the limit for injected transports, before decoding anything.
                guard response.data.count <= FoodRecognitionResponse.maximumResponseBytes else {
                    throw FoodRecognitionError.responseTooLarge
                }

                if attempt < retryCount, [502, 503, 504].contains(response.statusCode) {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }

                switch response.statusCode {
                case 200...299: break
                case 401, 403: throw FoodRecognitionError.unauthorized
                case 408, 504: throw FoodRecognitionError.timeout
                case 413: throw FoodRecognitionError.imageTooLarge
                case 422: throw FoodRecognitionError.unrecognized
                case 429: throw FoodRecognitionError.rateLimited
                case 500...599: throw FoodRecognitionError.serverUnavailable
                default: throw FoodRecognitionError.malformedResponse
                }

                let mimeType = response.mimeType?
                    .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                    .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                guard !response.data.isEmpty, mimeType == "application/json" else {
                    throw FoodRecognitionError.malformedResponse
                }
                let result = try FoodRecognitionResponse.decode(response.data)
                try Task.checkCancellation()
                return result
            }
            throw FoodRecognitionError.serverUnavailable
        } catch {
            // Transport failures (including offline/timeouts) never enter the retry path.
            if Task.isCancelled { throw FoodRecognitionError.cancelled }
            throw FoodRecognitionError.safe(error)
        }
    }
}