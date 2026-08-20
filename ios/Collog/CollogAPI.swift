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
        var usesRemoteTTS: Bool { ttsMode == "REMOTE_ASSET" && ttsAssetUrl != nil }
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

    // MARK: - 홈 대시보드 응답 모델

    // GET /parents/{parentId}/calls 의 한 건. 서버 datetime은 tz 유무가 섞이므로
    // 문자열로 받고 `startedAtDate`에서 관대하게 파싱한다.
    struct CallSummary: Decodable, Identifiable {
        let callId: String
        let parentId: String
        let childId: String
        let state: String
        let timeSlot: String?
        let startedAt: String
        let endedAt: String?
        let durationSec: Int?
        let recorded: Bool
        let parentSpeechSec: Int?
        let askedQuestionIds: [String]

        var id: String { callId }
        var startedAtDate: Date? { CollogAPI.parseServerDate(startedAt) }
        var isAnalyzed: Bool { state == "ANALYZED" }
    }

    private struct CallsResponse: Decodable {
        let calls: [CallSummary]
    }

    private struct DailyQuestionsResponse: Decodable {
        let source: String
        let questions: [Question]
    }

    // GET /parents/{parentId}/signals 의 한 건.
    struct ChangeSignal: Decodable, Identifiable {
        struct Comparison: Decodable {
            let deltaPct: Double
            let direction: String
            let robustZ: Double
            let significant: Bool
        }

        let signalId: String
        let metric: String
        let timeSlot: String
        let vsAnchor: Comparison?
        let vsRolling: Comparison?
        let consecutiveWeeks: Int
        let promoted: Bool
        let acute: Bool
        let summaryText: String?
        let acuteText: String?

        var id: String { signalId }
    }

    private struct SignalsResponse: Decodable {
        let signals: [ChangeSignal]
    }

    // GET /parents/{parentId}/reports 스냅샷.
    struct Report: Decodable {
        struct TrendPoint: Decodable {
            let date: String
            let value: Double
        }

        struct Trend: Decodable, Identifiable {
            let metric: String
            let points: [TrendPoint]

            var id: String { metric }
        }

        struct RepeatObservation: Decodable {
            let count: Int
            let callsWithRepeat: Int
            let label: String
            let ruleVersion: String?
        }

        let parentId: String
        let period: String
        let from: String
        let to: String
        /// `READY` / `EMPTY` / `BASELINE_COLLECTING`
        let state: String
        let emptyMessage: String?
        let disclaimer: String
        let advisory: String?
        let promotedSignals: [ChangeSignal]
        let acuteSignals: [ChangeSignal]
        let conversationItems: [String: [String]]
        let repeatObservation: RepeatObservation
        let acousticTrends: [Trend]
        let analyzedCallCount: Int

        var isReady: Bool { state == "READY" }
        var isBaselineCollecting: Bool { state == "BASELINE_COLLECTING" }
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

    // MARK: - 동의 (동의 확인 92:5415 / 동의 관리 92:5733)

    struct ConsentDocument: Decodable {
        let version: String
        let fullText: String
        let collectedItems: [String]
        let purpose: String
        let retentionPeriod: String
        let rawAudioPolicy: String
        let requiredItems: [String]
    }

    struct ConsentRecord: Decodable {
        let consentId: String
        let userId: String
        let documentVersion: String
        /// `GRANTED` 또는 `DENIED`. 요청 body의 `decision`은 `GRANT`/`DENY`인데
        /// 응답 `status`는 서버 enum(`ConsentDecision`) 값이라 어미가 다르다.
        let status: String
        let agreedItems: [String]
        let agreedAt: String

        var isGranted: Bool { status == "GRANTED" }
        var agreedAtDate: Date? { CollogAPI.parseServerDate(agreedAt) }
    }

    static func consentDocument() async throws -> ConsentDocument {
        try await send("/v1/consents/document", method: "GET", authenticated: false)
    }

    static func submitConsent(
        documentVersion: String,
        decision: String,
        scrolledToEnd: Bool,
        agreedItems: [String]
    ) async throws -> ConsentRecord {
        try await send(
            "/v1/consents",
            method: "POST",
            body: [
                "documentVersion": documentVersion,
                "decision": decision,
                "scrolledToEnd": scrolledToEnd,
                "agreedItems": agreedItems,
            ]
        )
    }

    /// 동의 기록이 없으면 서버가 404를 준다. 호출부에서 `nil`로 다룬다.
    static func myConsent() async throws -> ConsentRecord? {
        do {
            return try await send("/v1/consents/me", method: "GET") as ConsentRecord
        } catch APIError.status(404, _) {
            return nil
        }
    }

    // MARK: - 질환 프로필 (본인 프로필 생성 92:5339 / 질환 프로필 등록 92:4875)

    struct Profile: Decodable {
        let parentId: String
        let conditions: [String]
        let updatedAt: String?
    }

    /// 서버가 받는 질환 코드. 이 목록 밖의 값은 422로 거절된다.
    static let conditionCodes: [(code: String, label: String)] = [
        ("DIABETES", "당뇨"),
        ("HYPERTENSION", "고혈압"),
        ("DYSLIPIDEMIA", "고지혈증"),
        ("ASTHMA", "천식"),
        ("OBESITY", "비만"),
    ]

    static func profile(parentId: String) async throws -> Profile {
        try await send("/v1/parents/\(parentId)/profile", method: "GET")
    }

    static func updateProfile(parentId: String, conditions: [String]) async throws -> Profile {
        try await send(
            "/v1/parents/\(parentId)/profile",
            method: "PUT",
            body: ["conditions": conditions]
        )
    }

    // MARK: - 초대 (초대하기 92:5442 / 초대 확인 92:5472 / 초대 수락 92:5482)

    struct Invitation: Decodable {
        let invitationId: String
        let code: String
        let shareText: String
        let expiresAt: String
        /// `PENDING` / `ACCEPTED` / `EXPIRED`
        let status: String
    }

    struct InvitationAccepted: Decodable {
        let familyId: String
        let memberId: String
        let status: String
    }

    /// - Parameter relation: `MOTHER` 또는 `FATHER`
    static func createInvitation(
        familyId: String,
        name: String,
        relation: String
    ) async throws -> Invitation {
        try await send(
            "/v1/families/\(familyId)/invitations",
            method: "POST",
            body: ["name": name, "relation": relation]
        )
    }

    static func resendInvitation(invitationId: String) async throws -> Invitation {
        try await send("/v1/invitations/\(invitationId)/resend", method: "POST")
    }

    static func acceptInvitation(code: String) async throws -> InvitationAccepted {
        try await send("/v1/invitations/accept", method: "POST", body: ["code": code])
    }

    // MARK: - 통화 분석 결과 (건강 신호 분석 결과 92:5070)

    struct Extraction: Decodable {
        let callId: String
        /// `OK` 또는 `FAILED`
        let parseStatus: String
        let symptom: String?
        let medication: String?
        let activity: String?
        let sleep: String?
        let schemaVersion: String
    }

    struct AcousticFeatures: Decodable {
        struct Feature: Decodable, Identifiable {
            let metric: String
            let value: Double?
            let unit: String
            /// `OK` 또는 `UNMEASURABLE`
            let status: String
            let unmeasurableReason: String?

            var id: String { metric }
            var isMeasured: Bool { status == "OK" && value != nil }
        }

        let callId: String
        let audioSource: String
        let analyzerVersion: String?
        let coughDetectorVersion: String?
        let features: [Feature]
    }

    struct Transcript: Decodable {
        let callId: String
        let excluded: Bool
        let exclusionReason: String?
        let parentSpeechSec: Int
        let repeatRequestCount: Int
        let repeatRequestsPerMinute: Double
    }

    /// 분석 전이면 404다. 호출부에서 `nil`로 다룬다.
    static func extraction(callId: String) async throws -> Extraction? {
        do {
            return try await send("/v1/calls/\(callId)/extraction", method: "GET") as Extraction
        } catch APIError.status(404, _) {
            return nil
        }
    }

    static func acousticFeatures(callId: String) async throws -> AcousticFeatures? {
        do {
            return try await send(
                "/v1/calls/\(callId)/acoustic-features",
                method: "GET"
            ) as AcousticFeatures
        } catch APIError.status(404, _) {
            return nil
        }
    }

    static func transcript(callId: String) async throws -> Transcript? {
        do {
            return try await send("/v1/calls/\(callId)/transcript", method: "GET") as Transcript
        } catch APIError.status(404, _) {
            return nil
        }
    }

    // MARK: - 기준선 (건강 타임라인 92:5178 / 리포트 92:5138)

    struct Baseline: Decodable, Identifiable {
        let parentId: String
        let metric: String
        let timeSlot: String
        /// `ANCHOR` 또는 `ROLLING`
        let kind: String
        /// `COLLECTING` / `READY` / `UNSCORABLE`
        let status: String
        let sampleCount: Int
        let requiredCount: Int
        let remainingCalls: Int?
        let median: Double?

        var id: String { "\(metric)-\(timeSlot)-\(kind)" }
        var isReady: Bool { status == "READY" }
    }

    private struct BaselinesResponse: Decodable {
        let baselines: [Baseline]
    }

    static func baselines(parentId: String) async throws -> [Baseline] {
        let response: BaselinesResponse = try await send(
            "/v1/parents/\(parentId)/baseline",
            method: "GET"
        )
        return response.baselines
    }

    // MARK: - 건강 주체(subject) 조회
    //
    // 서버의 `/parents/{parentId}/*`는 CHILD면 접근 가능한 부모의 userId를,
    // PARENT면 자기 자신의 id를 받는다(`ensure_report_access`).

    static func dailyQuestions(parentId: String) async throws -> [Question] {
        let response: DailyQuestionsResponse = try await send(
            "/v1/parents/\(parentId)/daily-questions",
            method: "GET"
        )
        return response.questions
    }

    static func calls(parentId: String) async throws -> [CallSummary] {
        let response: CallsResponse = try await send(
            "/v1/parents/\(parentId)/calls",
            method: "GET"
        )
        return response.calls
    }

    static func signals(parentId: String, filter: String = "ALL") async throws -> [ChangeSignal] {
        let response: SignalsResponse = try await send(
            "/v1/parents/\(parentId)/signals",
            method: "GET",
            query: [URLQueryItem(name: "filter", value: filter)]
        )
        return response.signals
    }

    /// - Parameter period: `WEEKLY` 또는 `MONTHLY`
    static func report(parentId: String, period: String) async throws -> Report {
        try await send(
            "/v1/parents/\(parentId)/reports",
            method: "GET",
            query: [URLQueryItem(name: "period", value: period)]
        )
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
        query: [URLQueryItem]? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        let data = try await sendRaw(
            path,
            method: method,
            body: body,
            query: query,
            authenticated: authenticated
        )
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private static func sendRaw(
        _ path: String,
        method: String,
        body: [String: Any]?,
        query: [URLQueryItem]? = nil,
        authenticated: Bool = true
    ) async throws -> Data {
        // `appending(path:)`는 `?`까지 경로로 이스케이프하므로 query는 따로 붙인다.
        var url = baseURL.appending(path: path)
        if let query, !query.isEmpty {
            url.append(queryItems: query)
        }
        var request = URLRequest(url: url)
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

    // 서버는 tz가 붙은 값과 naive 값, 소수점 초가 있는 값과 없는 값을 모두 보낸다.
    // 네 조합을 순서대로 시도하고 실패하면 nil을 준다. 날짜를 지어내지 않는다.
    static func parseServerDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        for options in [
            [.withInternetDateTime, .withFractionalSeconds] as ISO8601DateFormatter.Options,
            [.withInternetDateTime],
        ] {
            iso.formatOptions = options
            if let date = iso.date(from: value) { return date }
        }
        // tz가 없는 naive 값은 서버 기준이 UTC다.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            naive.dateFormat = format
            if let date = naive.date(from: value) { return date }
        }
        return nil
    }

    // 서버 오류는 {"code": "...", "message": "..."} 형태다.
    private static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return object["message"] as? String ?? ""
    }
}
