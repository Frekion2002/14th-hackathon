import Foundation

// 콜록 backend REST 계약. camelCase 응답을 그대로 받는다.
enum CollogAPI {
    // 실기기는 localhost로 개발 PC에 닿지 못한다. 같은 Wi-Fi의 LAN IP를 넣는다.
    static var baseURL = URL(string: "http://127.0.0.1:8080")!
    static var accessToken: String?

    // MARK: - 응답 모델

    struct UserView: Codable {
        let id: String
        let role: String
        let name: String
        let phone: String
        let familyId: String?
    }

    struct TokenResponse: Codable {
        let accessToken: String
        let refreshToken: String
        let user: UserView
    }

    struct Member: Decodable, Identifiable {
        let memberId: String
        let userId: String?
        let name: String
        let relation: String
        let status: String
        let canRegisterConditions: Bool

        var id: String { memberId }
        var isCallable: Bool { userId != nil }
    }

    private struct MembersResponse: Decodable {
        let members: [Member]
    }

    struct Question: Decodable, Identifiable {
        let questionId: String
        let text: String
        let conditionCode: String?
        let ttsAssetUrl: String?
        let ttsMode: String

        var id: String { questionId }
        var usesLocalTTS: Bool { ttsMode == "IOS_LOCAL" }
    }

    struct AudioConstraints: Decodable {
        let echoCancellation: Bool
        let noiseSuppression: Bool
        let autoGainControl: Bool
        let dtx: Bool
        let audioBitrate: Int
        let rawCaptureSampleRate: Int
    }

    struct CallCreated: Decodable {
        let callId: String
        let livekitUrl: String
        let roomName: String
        let accessToken: String
        let recordingEnabled: Bool
        let recordingDisabledMessage: String?
        let questions: [Question]
        let audioConstraints: AudioConstraints
    }

    struct CallAccepted: Decodable {
        let callId: String
        let livekitUrl: String
        let roomName: String
        let accessToken: String
        let rawCaptureRequired: Bool
        let audioConstraints: AudioConstraints
    }

    struct DeviceCreated: Decodable {
        let deviceId: String
    }

    enum APIError: LocalizedError {
        case unauthenticated
        case status(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthenticated:
                return "로그인이 필요합니다"
            case let .status(code, message):
                return message.isEmpty ? "서버 오류 \(code)" : message
            }
        }
    }

    // MARK: - 인증

    static func requestOtp(phone: String, role: String, name: String) async throws {
        _ = try await sendRaw(
            "/v1/auth/otp/request",
            method: "POST",
            body: ["phone": phone, "role": role, "name": name],
            authenticated: false
        )
    }

    static func verifyOtp(phone: String, code: String) async throws -> TokenResponse {
        try await send(
            "/v1/auth/otp/verify",
            method: "POST",
            body: ["phone": phone, "code": code],
            authenticated: false
        )
    }

    // MARK: - 기기

    static func registerDevice(token: String, voipToken: String) async throws -> DeviceCreated {
        try await send(
            "/v1/devices",
            method: "POST",
            body: ["platform": "IOS", "token": token, "voipToken": voipToken]
        )
    }

    // MARK: - 가족

    static func members(familyId: String) async throws -> [Member] {
        let response: MembersResponse = try await send(
            "/v1/families/\(familyId)/members",
            method: "GET"
        )
        return response.members
    }

    // MARK: - 통화

    static func createCall(calleeId: String) async throws -> CallCreated {
        try await send("/v1/calls", method: "POST", body: ["calleeId": calleeId])
    }

    static func accept(callId: String) async throws -> CallAccepted {
        try await send("/v1/calls/\(callId)/accept", method: "POST")
    }

    static func decline(callId: String) async throws {
        _ = try await sendRaw("/v1/calls/\(callId)/decline", method: "POST", body: nil)
    }

    static func end(callId: String) async throws {
        _ = try await sendRaw("/v1/calls/\(callId)/end", method: "POST", body: nil)
    }

    // MARK: - 분석용 원본 오디오

    struct RawAudioUpload: Decodable {
        let uploadUrl: String
        let assetId: String
    }

    static func rawAudioUploadUrl(
        callId: String,
        durationSec: Double,
        sampleRate: Int
    ) async throws -> RawAudioUpload {
        try await send(
            "/v1/calls/\(callId)/raw-audio/upload-url",
            method: "POST",
            body: [
                "contentType": "audio/wav",
                "durationSec": durationSec,
                "sampleRate": sampleRate,
            ]
        )
    }

    static func uploadRawAudio(to urlString: String, fileURL: URL) async throws {
        guard let url = URL(string: urlString) else {
            throw APIError.status(0, "업로드 URL이 올바르지 않습니다")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.status(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func rawAudioComplete(callId: String, assetId: String) async throws {
        _ = try await sendRaw(
            "/v1/calls/\(callId)/raw-audio/complete",
            method: "POST",
            body: ["assetId": assetId]
        )
    }

    // MARK: - 전송

    private static func send<T: Decodable>(
        _ path: String,
        method: String,
        body: [String: Any]? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        let data = try await sendRaw(
            path,
            method: method,
            body: body,
            authenticated: authenticated
        )
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private static func sendRaw(
        _ path: String,
        method: String,
        body: [String: Any]?,
        authenticated: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if authenticated {
            guard let accessToken else { throw APIError.unauthenticated }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.status(code, errorMessage(from: data))
        }
        return data
    }

    // 서버 오류는 {"code": "...", "message": "..."} 형태다.
    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return object["message"] as? String ?? ""
    }
}
