# iOS 통화 연동 계약

## 고정 전제

- 클라이언트: Swift 네이티브, iOS 우선
- 통화 미디어: self-hosted LiveKit
- 수신 알림: APNs VoIP push → PushKit → CallKit
- 서버 인증: 콜록 JWT
- LiveKit 토큰은 APNs payload에 넣지 않는다. 사용자가 수락한 뒤 인증된 `/accept` 응답으로만
  전달한다.
- push payload에는 건강정보, 질환 프로필, 전화번호를 넣지 않는다.

## SDK 초기 설정

Swift Package Manager로 `https://github.com/livekit/client-sdk-swift`를 추가한다. CallKit이
오디오 세션 활성 시점을 소유하도록 앱 시작 초기에 LiveKit 자동 설정을 끈다.

```swift
import LiveKit

AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
try AudioManager.shared.setEngineAvailability(.none)
```

`CXProviderDelegate`는 CallKit이 넘긴 세션을 사용한다.

```swift
func provider(_ provider: CXProvider, didActivate session: AVAudioSession) {
    do {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers])
        try AudioManager.shared.setEngineAvailability(.default)
    } catch {
        // 통화 UI에 오디오 초기화 실패를 표시하고 통화를 종료한다.
    }
}

func provider(_ provider: CXProvider, didDeactivate session: AVAudioSession) {
    try? AudioManager.shared.setEngineAvailability(.none)
}
```

## Xcode 프로젝트 설정

서버가 쓰는 Bundle ID와 Xcode target의 Bundle Identifier는 반드시 같아야 한다. 서버는
`<Bundle ID>.voip`를 apns-topic으로 보낸다.

Signing & Capabilities에 다음을 추가한다.

- Push Notifications
- Background Modes > Voice over IP
- Background Modes > Audio, AirPlay, and Picture in Picture

`Info.plist`에는 마이크 사용 설명이 필요하다.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>통화 연결과 건강 기록을 위해 마이크를 사용합니다.</string>
```

iOS 13 이상에서 PushKit VoIP push를 받으면 **같은 실행 안에서 반드시**
`reportNewIncomingCall`을 호출해야 한다. 호출하지 않으면 시스템이 앱을 종료하고 반복되면
VoIP push 수신 권한을 잃는다.

```swift
import CallKit
import PushKit

final class VoipPushHandler: NSObject, PKPushRegistryDelegate {
    private let registry = PKPushRegistry(queue: .main)
    private let provider = CXProvider(configuration: {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        return configuration
    }())

    // 로그인 이후 한 번 호출한다. 토큰은 앱 실행마다 바뀔 수 있다.
    func start() {
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate credentials: PKPushCredentials,
        for type: PKPushType
    ) {
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        // POST /v1/devices의 voipToken으로 보낸다.
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let call = payload.dictionaryPayload["call"] as? [String: Any] ?? [:]
        let uuid = (call["callUUID"] as? String).flatMap(UUID.init) ?? UUID()
        let update = CXCallUpdate()
        update.localizedCallerName = call["callerName"] as? String ?? "콜록"
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in
            completion()
        }
    }
}
```

`didInvalidatePushTokenFor`를 받으면 서버 등록을 갱신하고, 앱 삭제/재설치 후에는 토큰이
바뀌므로 로그인 직후 항상 재등록한다.

## 토큰 등록

1. 일반 APNs remote-notification 토큰과 PushKit `.voIP` 토큰을 각각 hex 문자열로 만든다.
2. 로그인 직후와 토큰 갱신 시 `POST /v1/devices`를 호출한다.
3. 동일 설치의 재등록은 서버가 upsert한다.

```json
{
  "platform": "IOS",
  "token": "일반 APNs device token",
  "voipToken": "PushKit VoIP token"
}
```

## 발신자 흐름

1. `POST /v1/calls { "calleeId": parentId }`
2. 응답의 `questions` 중 `ttsMode == IOS_LOCAL`인 문장을 `AVSpeechSynthesizer`의 `ko-KR`
   음성으로 발신자에게만 재생한다. 이 음원은 통화 상대에게 송출하지 않는다.
3. 응답의 `livekitUrl`, `accessToken`으로 room에 접속한다.
4. 부모가 수락하면 부모도 같은 room에 접속한다.
5. 종료 시 `POST /v1/calls/{callId}/end`를 호출한다.

Deepgram Aura TTS API 자체는 존재하지만 2026-08-11 공식 지원 언어에 한국어가 없다. 따라서
현재 `ttsAssetUrl`은 `null`, `ttsMode`는 `IOS_LOCAL`이며 STT에 쓰는 Deepgram key 외에 TTS용
key는 추가하지 않는다. 추후 한국어 server TTS provider를 선택하면 서버가 미리 생성한 URL을
`ttsAssetUrl`로 반환하고 `ttsMode=REMOTE_ASSET`으로 바꿀 수 있다.

```swift
import AVFoundation

@MainActor
final class RingingQuestionSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    // /accept에 해당하는 수신 상태 또는 LiveKit parent participant 연결 즉시 호출한다.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
```

재생은 발신자가 `POST /calls` 응답을 받은 뒤 시작하고, 부모 수락 event가 오면 문장 중간이어도
즉시 중단한다. 질문은 화면에도 같은 text로 표시한다. 재생 실패가 통화 연결을 막아서는 안 되며,
질문 두 개를 모두 읽느라 수신 연결을 늦추지 않는다. 초기 데모에서는 첫 질문 한 개만 최대
3~5초 재생하고 나머지는 통화 화면의 참고 질문으로 표시한다.

## 수신자 흐름

APNs payload는 다음 모양이다.

```json
{
  "aps": { "content-available": 1 },
  "call": {
    "callId": "UUID",
    "callUUID": "동일한 UUID",
    "callerId": "자녀 user id",
    "callerName": "김철수",
    "expiresAt": "ISO-8601"
  }
}
```

PushKit delegate에서는 네트워크 요청보다 먼저 `reportNewIncomingCall`을 호출한다. 동일
`callUUID`를 `CXCallUpdate`와 이후 answer/end action에 계속 사용한다. CallKit 보고가 성공한
뒤 PushKit completion을 호출한다.

사용자가 수락하면 다음 순서로 처리한다.

1. `POST /v1/calls/{callId}/accept`
2. 응답의 `livekitUrl`, `accessToken`으로 room 접속
3. CallKit `didActivate` 이후 마이크 publish
4. `rawCaptureRequired == true`이면 분석용 PCM renderer 부착
5. 모두 성공하면 `CXAnswerCallAction.fulfill()`

거절은 `/decline`, 정상 종료는 `/end`를 호출한다. 앱이 push를 늦게 받았거나 `expiresAt`이
지났으면 CallKit에 새 통화를 보고하지 않는다.

## 오디오 캡처 옵션

콜록은 기침과 발화 특성을 보존하되 실제 통화의 하울링을 막아야 한다.

```swift
let captureOptions = AudioCaptureOptions(
    echoCancellation: true,
    autoGainControl: false,
    noiseSuppression: false,
    highpassFilter: false,
    typingNoiseDetection: false
)

let publication = try await room.localParticipant.setMicrophone(
    enabled: true,
    captureOptions: captureOptions
)
```

서버의 `audioConstraints`와 값이 다르면 통화를 시작하지 말고 로깅한다. DTX와 audio bitrate는
publish options/codec 설정에서 별도로 적용하고, 실제 패킷 통계를 실기기에서 확인한다.

## 분석용 PCM 기록

별도 `AVAudioEngine` input tap을 만들지 않는다. LiveKit의 같은 캡처 스트림을 관찰하는
`AudioRenderer`를 `LocalAudioTrack`에 부착한다.

```swift
final class AnalysisPCMWriter: AudioRenderer, @unchecked Sendable {
    func render(pcmBuffer: AVAudioPCMBuffer) {
        // SDK가 buffer를 재사용할 수 있으므로 callback 안에서 복사한 뒤
        // 전용 serial queue에서 WAV/CAF 파일에 기록한다.
    }
}

if let track = publication?.track as? LocalAudioTrack {
    track.add(audioRenderer: analysisWriter)
}
```

이 renderer는 LiveKit의 capture post-processing PCM을 받는다. 따라서 제품 문서의 “원시
마이크”는 하드웨어 처리 전 원본이 아니라, `AEC=true`, `AGC/NS=false` 조건을 적용한 분석용
PCM으로 정의한다. 파일은 mono 48 kHz signed 16-bit little-endian PCM WAV로 정규화한다.
float32 WAV나 CAF를 그대로 올리면 서버가 `INVALID_AUDIO`로 거부한다.

종료 시 renderer를 먼저 제거하고 파일을 닫는다.

1. `POST /raw-audio/upload-url`
2. presigned URL에 `PUT audio/wav`
3. `POST /raw-audio/complete`

업로드가 실패하면 재시도 가능한 앱 전용 임시 영역에만 짧게 보관하고, 완료 또는 만료 시 즉시
삭제한다. 서버도 분석 완료 후 원본을 폐기한다.

## 팀 포털 WebView (개발 빌드 전용)

백엔드의 `/team`은 모바일 대응 HTML이므로 별도 화면 구현 없이 `WKWebView`로 열 수 있다.
고객용 건강 리포트 화면이 아니라 팀 통합 상태를 보는 개발 도구이므로 Debug build에서만
노출한다.

```swift
import SwiftUI
import WebKit

struct TeamHubWebView: UIViewRepresentable {
    let backendBaseURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let teamURL = backendBaseURL.appending(path: "team")
        if view.url != teamURL {
            view.load(URLRequest(url: teamURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
}
```

같은 Wi-Fi의 개발 PC를 직접 열 때에는 `http://<개발-PC-LAN-IP>:8080`을 사용한다.
Info.plist에는 광범위한 `NSAllowsArbitraryLoads` 대신 개발 target에만
`NSLocalNetworkUsageDescription`과 필요한 local-network 예외를 둔다. 외부 공유나 TestFlight는
TLS가 적용된 backend URL을 사용하고 production config에서는 `TEAM_PORTAL_ENABLED=false`로
설정한다.

## 아직 실기기에서 검증할 것

- PushKit background launch → CallKit 보고 시간
- CallKit 활성화 전/후 LiveKit room 접속과 마이크 publish 타이밍
- receiver route, speaker, Bluetooth 전환
- renderer PCM의 실제 sample rate/channel과 48 kHz mono 변환
- `AGC=false`, `NS=false`, `DTX=false`가 iPhone 실기기에서 유지되는지
- 화면 잠금/통화 중단/네트워크 전환 시 파일 종료와 재업로드

참고: [Apple PushKit VoIP notifications](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit),
[Apple APNs provider requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[LiveKit Swift SDK CallKit integration](https://github.com/livekit/client-sdk-swift#integration-with-callkit),
[Deepgram Aura voices/languages](https://developers.deepgram.com/docs/tts-models).
