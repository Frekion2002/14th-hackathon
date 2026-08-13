import Foundation

// 콜록 backend REST 계약. camelCase 응답을 그대로 받는다.
enum CollogAPI {
    // 실기기는 localhost로 개발 PC에 닿지 못한다. 같은 Wi-Fi의 LAN IP를 넣는다.
    static var baseURL = URL(string: "http://127.0.0.1:8080")!
    // 로그인 구현 전까지는 비어 있다. 비어 있으면 기기 등록을 건너뛴다.
    static var accessToken: String?

    struct DeviceCreated: Decodable {
        let deviceId: String
    }

    struct CallAccepted: Decodable {
        let callId: String
        let livekitUrl: String
        let roomName: String
        let accessToken: String
        let rawCaptureRequired: Bool
    }

    enum APIError: LocalizedError {
        case unauthenticated
        case status(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthenticated:
                return "로그인 토큰이 없습니다"
            case let .status(code, body):
                return "서버 오류 \(code): \(body)"
            }
        }
    }

    static func registerDevice(token: String, voipToken: String) async throws -> DeviceCreated {
        try await send(
            "/v1/devices",
            body: ["platform": "IOS", "token": token, "voipToken": voipToken]
        )
    }

    static func accept(callId: String) async throws -> CallAccepted {
        try await send("/v1/calls/\(callId)/accept")
    }

    static func decline(callId: String) async throws {
        _ = try await sendRaw("/v1/calls/\(callId)/decline", body: nil)
    }

    static func end(callId: String) async throws {
        _ = try await sendRaw("/v1/calls/\(callId)/end", body: nil)
    }

    private static func send<T: Decodable>(
        _ path: String,
        body: [String: Any]? = nil
    ) async throws -> T {
        let data = try await sendRaw(path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func sendRaw(_ path: String, body: [String: Any]?) async throws -> Data {
        guard let accessToken else { throw APIError.unauthenticated }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.status(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
