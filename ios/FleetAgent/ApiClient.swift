import Foundation
import UIKit

enum EnrollmentState: Equatable {
    case unenrolled
    case enrolling
    case enrolled
    case error(String)
}

/// HTTP client for Fleet Orbit API. Handles enrollment, credential management,
/// and automatic re-enrollment on 401 responses.
@MainActor
class ApiClient: ObservableObject {
    @Published var enrollmentState: EnrollmentState = .unenrolled

    let keychain: KeychainManager
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init() {
        self.init(sessionConfiguration: nil, keychain: .shared)
    }

    init(sessionConfiguration: URLSessionConfiguration?, keychain: KeychainManager = .shared) {
        self.keychain = keychain
        let config = sessionConfiguration ?? {
            let c = URLSessionConfiguration.default
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 60
            return c
        }()

        #if DEBUG
        // Accept self-signed certificates for local Fleet dev server
        let delegate = SelfSignedCertDelegate()
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        #else
        self.session = URLSession(configuration: config)
        #endif

        if keychain.loadOrbitNodeKey() != nil {
            enrollmentState = .enrolled
        }
    }

    // MARK: - Enrollment

    /// Enroll with Fleet server. Stores orbit_node_key in Keychain on success.
    func enroll(config: ConfigurationManager) async {
        guard config.isConfigured else {
            enrollmentState = .error("Not configured")
            return
        }

        if case .enrolling = enrollmentState { return }

        enrollmentState = .enrolling

        let hardwareUUID = config.hostUUID.isEmpty
            ? (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
            : config.hostUUID

        let request = EnrollRequest(
            enrollSecret: config.enrollSecret,
            hardwareUUID: hardwareUUID,
            hardwareSerial: hardwareUUID,
            platform: "ios",
            computerName: UIDevice.current.name
        )

        do {
            let response: EnrollResponse = try await post(
                baseURL: config.serverURL,
                path: "/api/fleet/orbit/enroll",
                body: request
            )

            if keychain.saveOrbitNodeKey(response.orbitNodeKey) {
                enrollmentState = .enrolled
                print("[Fleet] Enrollment successful")
            } else {
                enrollmentState = .error("Failed to save node key to Keychain")
            }
        } catch {
            enrollmentState = .error(error.localizedDescription)
            print("[Fleet] Enrollment failed: \(error)")
        }
    }

    /// Clear stored node key and mark as unenrolled.
    func clearEnrollment() {
        keychain.deleteOrbitNodeKey()
        enrollmentState = .unenrolled
        print("[Fleet] Enrollment cleared")
    }

    /// Returns the stored orbit node key, enrolling first if needed.
    func getNodeKeyOrEnroll(config: ConfigurationManager) async -> String? {
        if let key = keychain.loadOrbitNodeKey() {
            return key
        }
        await enroll(config: config)
        return keychain.loadOrbitNodeKey()
    }

    /// Executes an async block. On 401, clears credentials, re-enrolls, and retries once.
    func withReenrollOnUnauthorized<T>(
        config: ConfigurationManager,
        block: () async throws -> T
    ) async throws -> T {
        do {
            return try await block()
        } catch let error as ApiError where error.statusCode == 401 {
            print("[Fleet] 401 received, re-enrolling")
            clearEnrollment()
            await enroll(config: config)
            return try await block()
        }
    }

    /// Truncated node key for display (first 8 chars + "...").
    var maskedNodeKey: String? {
        guard let key = keychain.loadOrbitNodeKey() else { return nil }
        if key.count <= 8 { return key }
        return String(key.prefix(8)) + "..."
    }

    // MARK: - HTTP

    private func post<Req: Encodable, Resp: Decodable>(
        baseURL: String,
        path: String,
        body: Req
    ) async throws -> Resp {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else {
            throw ApiError(statusCode: 0, message: "Invalid URL: \(base + path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ApiError(statusCode: 0, message: "Not an HTTP response")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ApiError(statusCode: http.statusCode, message: "HTTP \(http.statusCode): \(body)")
        }

        return try decoder.decode(Resp.self, from: data)
    }
}

// MARK: - Request/Response Models

struct EnrollRequest: Encodable {
    let enrollSecret: String
    let hardwareUUID: String
    let hardwareSerial: String
    let platform: String
    let computerName: String

    enum CodingKeys: String, CodingKey {
        case enrollSecret = "enroll_secret"
        case hardwareUUID = "hardware_uuid"
        case hardwareSerial = "hardware_serial"
        case platform
        case computerName = "computer_name"
    }
}

struct EnrollResponse: Decodable {
    let orbitNodeKey: String

    enum CodingKeys: String, CodingKey {
        case orbitNodeKey = "orbit_node_key"
    }
}

struct ApiError: Error, LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? { message }
}

// MARK: - Self-Signed Certificate Support (DEBUG only)

#if DEBUG
private class SelfSignedCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#endif
