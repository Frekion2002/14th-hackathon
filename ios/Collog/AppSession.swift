import Combine
import Foundation

// 로그인 세션과 가족 구성원 목록. 해커톤 개발 빌드라 토큰을 UserDefaults에 둔다.
// 실사용 배포 전에는 Keychain으로 옮긴다.
@MainActor
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published private(set) var user: CollogAPI.UserView?
    @Published private(set) var members: [CollogAPI.Member] = []
    @Published var errorMessage: String?
    @Published private(set) var isWorking = false

    private let tokenKey = "collog.accessToken"
    private let userKey = "collog.user"
    private let baseURLKey = "collog.baseURL"

    var isLoggedIn: Bool { user != nil }

    var backendBaseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? CollogAPI.baseURL.absoluteString }
        set {
            guard let url = URL(string: newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: baseURLKey)
            CollogAPI.baseURL = url
        }
    }

    private init() {
        if let stored = UserDefaults.standard.string(forKey: baseURLKey),
           let url = URL(string: stored) {
            CollogAPI.baseURL = url
        }
        CollogAPI.accessToken = UserDefaults.standard.string(forKey: tokenKey)
        if let data = UserDefaults.standard.data(forKey: userKey) {
            user = try? JSONDecoder().decode(CollogAPI.UserView.self, from: data)
        }
    }

    func requestOtp(phone: String, role: String, name: String) async -> Bool {
        await perform {
            try await CollogAPI.requestOtp(phone: phone, role: role, name: name)
        }
    }

    func verifyOtp(phone: String, code: String) async -> Bool {
        await perform {
            let response = try await CollogAPI.verifyOtp(phone: phone, code: code)
            CollogAPI.accessToken = response.accessToken
            UserDefaults.standard.set(response.accessToken, forKey: self.tokenKey)
            if let encoded = try? JSONEncoder().encode(response.user) {
                UserDefaults.standard.set(encoded, forKey: self.userKey)
            }
            self.user = response.user
            // 로그인 전에 발급된 PushKit 토큰을 이 시점에 서버로 올린다.
            VoipCallCenter.shared.registerDeviceIfPossible()
            await self.refreshMembers()
        }
    }

    func logout() {
        CollogAPI.accessToken = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        user = nil
        members = []
    }

    func refreshMembers() async {
        guard let familyId = user?.familyId else { return }
        do {
            members = try await CollogAPI.members(familyId: familyId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func perform(_ work: @MainActor () async throws -> Void) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
