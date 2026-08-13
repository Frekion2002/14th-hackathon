import AVFAudio
import CallKit
import Combine
import Foundation
import PushKit
import UIKit

// PushKit VoIP push를 CallKit 수신 화면으로 연결하고, 사용자가 수락하면 backend /accept를
// 호출한다. LiveKit room 접속은 SDK를 추가한 뒤 connectMedia/disconnectMedia에 채운다.
@MainActor
final class VoipCallCenter: NSObject, ObservableObject {
    static let shared = VoipCallCenter()

    @Published private(set) var voipToken: String?
    @Published private(set) var apnsToken: String?
    @Published private(set) var events: [String] = []

    private let registry = PKPushRegistry(queue: .main)
    private let callController = CXCallController()
    private lazy var provider: CXProvider = {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        return CXProvider(configuration: configuration)
    }()

    private var activeCallId: String?
    private var answeredCallIds: Set<String> = []

    func start() {
        provider.setDelegate(self, queue: nil)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        UIApplication.shared.registerForRemoteNotifications()
        log("PushKit 등록 시작")
    }

    func setRemoteNotificationToken(_ deviceToken: Data) {
        apnsToken = deviceToken.hexString
        log("APNs 토큰 수신")
        registerDeviceIfPossible()
    }

    func log(_ message: String) {
        events.insert(message, at: 0)
        events = Array(events.prefix(30))
        print("[Collog] \(message)")
    }

    private func registerDeviceIfPossible() {
        guard let apnsToken, let voipToken, CollogAPI.accessToken != nil else { return }
        Task {
            do {
                _ = try await CollogAPI.registerDevice(token: apnsToken, voipToken: voipToken)
                log("기기 등록 완료")
            } catch {
                log("기기 등록 실패: \(error.localizedDescription)")
            }
        }
    }

    // LiveKit SDK를 추가한 뒤 room 접속/해제를 여기에 구현한다. CallKit이 오디오 세션을
    // 활성화하기 전에 track publish를 시작하지 않는다.
    private func connectMedia(_ accepted: CollogAPI.CallAccepted) async throws {
        log("LiveKit 접속 대상 room=\(accepted.roomName)")
    }

    private func disconnectMedia() {
        log("LiveKit 연결 해제")
    }
}

extension VoipCallCenter: PKPushRegistryDelegate {
    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate credentials: PKPushCredentials,
        for type: PKPushType
    ) {
        MainActor.assumeIsolated {
            voipToken = credentials.token.hexString
            log("VoIP 토큰: \(voipToken ?? "-")")
            registerDeviceIfPossible()
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        MainActor.assumeIsolated {
            voipToken = nil
            log("VoIP 토큰 무효화")
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            // iOS는 VoIP push를 받은 실행 안에서 반드시 reportNewIncomingCall을 호출하도록
            // 강제한다. 네트워크 요청은 사용자가 수락한 뒤에 한다.
            let call = payload.dictionaryPayload["call"] as? [String: Any] ?? [:]
            let callId = call["callId"] as? String
            let uuid = (call["callUUID"] as? String).flatMap(UUID.init) ?? UUID()

            if let expiresAt = call["expiresAt"] as? String,
               let expiry = Date.fromCollogISO8601(expiresAt),
               expiry < Date() {
                log("만료된 push 무시: \(callId ?? "-")")
                reportAndImmediatelyEnd(uuid: uuid, completion: completion)
                return
            }

            activeCallId = callId
            let update = CXCallUpdate()
            update.localizedCallerName = call["callerName"] as? String ?? "콜록"
            update.remoteHandle = CXHandle(
                type: .generic,
                value: call["callerId"] as? String ?? "collog"
            )
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false

            let callerName = update.localizedCallerName ?? "-"
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                MainActor.assumeIsolated {
                    if let error {
                        self?.log("CallKit 보고 실패: \(error.localizedDescription)")
                    } else {
                        self?.log("수신 통화 표시: \(callerName)")
                    }
                    completion()
                }
            }
        }
    }

    // CallKit에 보고하지 않고 completion만 호출하면 앱이 종료되므로, 무시할 push도 한 번
    // 보고한 뒤 즉시 종료한다.
    private func reportAndImmediatelyEnd(uuid: UUID, completion: @escaping () -> Void) {
        let update = CXCallUpdate()
        update.localizedCallerName = "콜록"
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
                completion()
            }
        }
    }
}

extension VoipCallCenter: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            disconnectMedia()
            activeCallId = nil
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            guard let callId = activeCallId else {
                action.fail()
                return
            }
            answeredCallIds.insert(callId)
            Task {
                do {
                    let accepted = try await CollogAPI.accept(callId: callId)
                    try await connectMedia(accepted)
                    action.fulfill()
                    log("수락 완료: \(callId)")
                } catch {
                    log("수락 실패: \(error.localizedDescription)")
                    action.fail()
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            let callId = activeCallId
            let answered = callId.map { answeredCallIds.contains($0) } ?? false
            disconnectMedia()
            activeCallId = nil
            action.fulfill()
            guard let callId else { return }
            answeredCallIds.remove(callId)
            Task {
                do {
                    // 수락 전 종료는 거절, 수락 뒤 종료는 정상 종료다.
                    if answered {
                        try await CollogAPI.end(callId: callId)
                    } else {
                        try await CollogAPI.decline(callId: callId)
                    }
                } catch {
                    log("종료 보고 실패: \(error.localizedDescription)")
                }
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate session: AVAudioSession) {
        MainActor.assumeIsolated {
            // LiveKit AudioManager의 engine availability를 여기에서 켠다.
            log("오디오 세션 활성화")
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate session: AVAudioSession) {
        MainActor.assumeIsolated {
            log("오디오 세션 비활성화")
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Date {
    // 서버는 microsecond 정밀도 ISO-8601을 보낸다. 소수점 유무 양쪽을 모두 시도한다.
    static func fromCollogISO8601(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
