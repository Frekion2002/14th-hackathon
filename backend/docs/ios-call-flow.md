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
2. 응답의 `questions` 중 TTS 문장을 발신자에게 로컬 재생한다. 이 음원은 통화 상대에게
   송출하지 않는다.
3. 응답의 `livekitUrl`, `accessToken`으로 room에 접속한다.
4. 부모가 수락하면 부모도 같은 room에 접속한다.
5. 종료 시 `POST /v1/calls/{callId}/end`를 호출한다.

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
PCM으로 정의한다. 파일은 mono 48 kHz PCM WAV로 정규화한다.

종료 시 renderer를 먼저 제거하고 파일을 닫는다.

1. `POST /raw-audio/upload-url`
2. presigned URL에 `PUT audio/wav`
3. `POST /raw-audio/complete`

업로드가 실패하면 재시도 가능한 앱 전용 임시 영역에만 짧게 보관하고, 완료 또는 만료 시 즉시
삭제한다. 서버도 분석 완료 후 원본을 폐기한다.

## 아직 실기기에서 검증할 것

- PushKit background launch → CallKit 보고 시간
- CallKit 활성화 전/후 LiveKit room 접속과 마이크 publish 타이밍
- receiver route, speaker, Bluetooth 전환
- renderer PCM의 실제 sample rate/channel과 48 kHz mono 변환
- `AGC=false`, `NS=false`, `DTX=false`가 iPhone 실기기에서 유지되는지
- 화면 잠금/통화 중단/네트워크 전환 시 파일 종료와 재업로드

참고: [Apple PushKit VoIP notifications](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit),
[Apple APNs provider requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[LiveKit Swift SDK CallKit integration](https://github.com/livekit/client-sdk-swift#integration-with-callkit).
