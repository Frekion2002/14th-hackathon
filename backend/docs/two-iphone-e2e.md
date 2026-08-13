# iPhone 2대 양방향 통화 E2E 검증

이 문서는 자녀 iPhone과 부모 iPhone의 실제 통화가 APNs/CallKit, self-hosted LiveKit,
Track Egress, Deepgram, Gemini, 음향 분석, 원본 폐기까지 이어지는지 한 번에 검증하는 절차다.
시뮬레이터 한 대나 room join 성공만으로는 양방향 통화를 증명하지 않는다.

## 합격 기준

수동 확인:

- 부모 iPhone이 잠겨 있어도 CallKit 수신 화면이 뜬다.
- 자녀에게 연결 대기 질문이 들린다. ElevenLabs 설정 시 서버 음성, 미설정/실패 시 iOS 음성이다.
- 부모가 받는 순간 질문 음성이 즉시 멈춘다.
- 자녀가 말한 문장을 부모가 듣고, 부모가 말한 문장을 자녀가 듣는다.
- 스피커/수화부 전환과 종료가 두 기기 모두 정상이다.

자동 확인(`scripts.verify_two_iphone_call`):

- 통화 수락·종료·30초 이상 지속
- 부모/자녀 LiveKit Track Egress 두 개와 Egress ID 두 개
- 부모 기기의 분석용 raw PCM
- Deepgram 결과에 `PARENT`, `CHILD` 양쪽 화자 segment
- 음향 지표 4종(`COUGH_EVENTS`, `SPEECH_RATE`, `PAUSE_RATIO`, `F0_VARIATION`)
- 최종 상태 `ANALYZED`, pipeline error 없음
- 분석 직후 Egress와 raw PCM이 모두 `PURGED`, 폐기 시각 기록

실제로 상대 음성이 들렸는지는 서버가 완전히 증명할 수 없으므로 수동 확인과 자동 확인이 모두
통과해야 최종 합격이다.

## 1. 준비물

- Apple Developer Team에 등록된 iPhone 2대
- 두 기기에 설치할 동일한 개발 빌드 (`aps-environment=development`)
- Push Notifications와 Background Modes(Voice over IP, Audio) capability
- APNs Auth Key `.p8`, Team ID, Key ID, 앱 Bundle ID
- Deepgram API key, Gemini API key
- ElevenLabs를 쓸 경우 API key와 한국어 voice ID
- Docker Desktop이 실행 중인 Mac과 두 iPhone이 접속한 동일 Wi-Fi

공용 Wi-Fi의 client isolation이 켜져 있으면 iPhone에서 Mac에 접근할 수 없다. 개인 핫스팟이나
같은 공유기로 바꾸고 VPN은 잠시 끈다.

## 2. Mac의 LAN 주소와 포트

Wi-Fi 인터페이스의 주소를 찾는다.

```bash
ipconfig getifaddr en0
```

예시 결과가 `192.168.0.10`이라면 `backend/.env`의 기기 접근 주소를 다음처럼 맞춘다. 아래
값의 `192.168.0.10`만 실제 값으로 바꾼다.

```dotenv
PUBLIC_BASE_URL=http://192.168.0.10:8080
LIVEKIT_URL=ws://192.168.0.10:7880
S3_PUBLIC_ENDPOINT_URL=http://192.168.0.10:9000

MOCK_EXTERNAL_SERVICES=false
APNS_VOIP_ENABLED=true
APNS_ENVIRONMENT=sandbox
APNS_TEAM_ID=...
APNS_KEY_ID=...
APNS_BUNDLE_ID=...
APNS_PRIVATE_KEY_PATH=/run/secrets/AuthKey_XXXXXXXXXX.p8

DEEPGRAM_API_KEY=...
GEMINI_API_KEY=...

QUESTION_TTS_PROVIDER=elevenlabs
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
ELEVENLABS_MODEL=eleven_flash_v2_5
```

`.p8` 파일은 `backend/private/AuthKey_XXXXXXXXXX.p8`에 둔다. compose가 이 디렉터리를
`/run/secrets/collog`에 read-only로 mount하므로 `APNS_PRIVATE_KEY_PATH`에는 위 예시처럼
컨테이너 내부 경로를 쓴다. 파일은 `.gitignore`의 `*.p8` 규칙으로 제외된다.

필요한 inbound 포트는 다음과 같다.

| 포트 | 용도 |
|---|---|
| TCP 8080 | Backend/API와 로컬 TTS asset |
| TCP 7880 | LiveKit WebSocket/API |
| TCP 7881 | LiveKit RTC TCP fallback |
| UDP 7882 | LiveKit RTC media |
| TCP 9000 | iPhone의 MinIO raw PCM 업로드 |

macOS 방화벽이 Docker의 수신을 차단하면 허용한다. 인터넷에 이 포트들을 포트포워딩할 필요는
없다.

## 3. 서버 실행과 사전 점검

```bash
cd backend
docker compose up --build
```

다른 터미널에서 다음을 확인한다.

```bash
curl --fail http://127.0.0.1:8080/v1/health
curl --fail http://127.0.0.1:8080/team/status.json
docker compose ps
docker compose exec backend python -m scripts.preflight_two_iphone
```

iPhone Safari에서도 `http://192.168.0.10:8080/team`을 연다. 여기서 열리지 않으면 Xcode나
APNs로 넘어가지 말고 Wi-Fi, LAN IP, 방화벽부터 해결한다. Team Hub의 APNs, Deepgram,
Gemini, LiveKit, 질문 TTS 설정 상태도 확인한다.

APNs 자격증명과 각 iPhone의 PushKit 토큰은 다음으로 별도 확인할 수 있다.

```bash
cd backend
uv run python -m scripts.check_apns --device-token <부모-iPhone-VoIP-token> --environment sandbox
```

## 4. 데모 가족 만들기

서버가 실행된 상태에서 자녀·부모 계정, 초대, 부모 동의, 질환 프로필을 한 번에 만든다.

```bash
cd backend
uv run python -m scripts.seed_demo_family \
  --base-url http://127.0.0.1:8080 \
  --child-phone 01000000002 \
  --parent-phone 01000000010 \
  --conditions HYPERTENSION
```

개발 OTP는 `000000`이다. 실데이터 대신 위 더미 계정을 사용한다.

## 5. 두 iPhone 설치와 로그인

1. Xcode에서 `ios/Collog.xcodeproj`를 열고 Team, Bundle Identifier, signing을 설정한다.
2. 두 iPhone에 같은 개발 빌드를 직접 설치한다.
3. 처음 묻는 마이크, 알림, 로컬 네트워크 권한을 허용한다.
4. 두 기기 로그인 화면의 서버 주소에 `http://192.168.0.10:8080`을 입력한다.
5. 자녀 iPhone은 `01000000002 / CHILD`, 부모 iPhone은 `01000000010 / PARENT`로 로그인한다.
6. 두 기기의 개발 정보에 VoIP 토큰이 보이고 `기기 등록 완료` 로그가 있는지 확인한다.
7. 부모 앱을 background로 보내고 화면을 잠근다.

iOS 17 이상에서 LAN IP의 HTTP 접근은 기본 ATS 정책에 걸릴 수 있다. 개발 빌드에는
`NSAllowsLocalNetworking`과 `NSLocalNetworkUsageDescription`이 들어 있다. 운영 배포에서는
반드시 HTTPS/WSS를 사용하고 예외를 제거한다.

## 6. 고정 대화로 통화

자녀가 부모 카드의 전화 버튼을 누른다.

1. 자녀가 ElevenLabs 연결 질문을 듣는다.
2. 잠긴 부모 iPhone의 CallKit 화면에서 받는다.
3. 질문이 멈추고 양쪽에 아래 문장을 번갈아 읽는다.

자녀 통화 화면에는 녹색 `ElevenLabs 음성` badge가 보여야 하며, 개발 정보의 이벤트 로그에는
수락 전 다음 세 줄이 순서대로 남아야 한다.

```text
질문 음성 계약: ElevenLabs REMOTE_ASSET
ElevenLabs 질문 음성 로딩
ElevenLabs 질문 음성 재생 시작
```

부모가 받으면 `상대 연결로 질문 음성 즉시 중단`, `상대 참가: ...`가 이어진다. `iOS 폴백
음성` badge나 `ElevenLabs 질문 재생 실패 → iOS 로컬 음성`이 보이면 통화 자체는 계속할 수
있지만 ElevenLabs 항목은 실패다. 개발 정보의 `전체 로그 복사`로 증빙을 저장한다.

```text
자녀: 오늘 산책은 하셨어요? 제 목소리가 잘 들리세요?
부모: 뭐라고? 이제 잘 들린다. 오늘 공원을 삼십 분 걸었어.
자녀: 어젯밤에는 푹 주무셨어요?
부모: 어젯밤에는 기침 때문에 한 번 깼지만 약은 평소대로 먹었어.
```

각자 상대가 한 말을 그대로 한 번 복창해 실제 remote audio render까지 확인한다. 두 기기 모두
`오디오 세션 활성화`, `마이크 publish 완료`, `상대 참가` 로그가 있어야 한다. 최소 30초, 권장
45초 이상 말하고 자녀에서 종료한다. 자녀 이벤트 로그의 `발신 통화 생성: <UUID>`를 복사할
수 있으며, 복사하지 못해도 검증기는 최신 통화를 찾는다.

## 7. 자동 판정

통화를 끝낸 직후 최대 3분 동안 분석 완료를 기다리며 검사한다.

```bash
cd backend
uv run python -m scripts.verify_two_iphone_call --call-id <UUID>
```

Docker 내부 PostgreSQL을 사용하는 표준 compose 실행에서는 다음 명령을 쓴다.

```bash
cd backend
docker compose exec backend python -m scripts.verify_two_iphone_call --call-id <UUID>
```

UUID를 생략하면 최신 통화를 검사한다. `"passed": true`와 모든 check의 `passed: true`가
합격이다. 부모가 30초 미만 말해 의도적으로 분석 제외된 경우에만 원인을 확인한 뒤
`--allow-excluded`를 사용할 수 있으며, 해커톤 최종 실기기 증빙은 제외 없이 통과해야 한다.

## 8. 장애별 분리 진단

| 증상 | 먼저 볼 것 |
|---|---|
| Safari에서 Team Hub가 안 열림 | LAN IP, 동일 Wi-Fi, client isolation, macOS 방화벽, 8080 |
| 부모 CallKit이 안 뜸 | 부모 VoIP token 등록, APNs sandbox, Team/Key/Bundle ID, `.p8` mount |
| CallKit은 뜨지만 연결 실패 | `LIVEKIT_URL`이 localhost인지, 7880/7881/7882, 로컬 네트워크 권한 |
| 한 방향만 들림 | 두 기기의 `마이크 publish 완료`, CallKit `오디오 세션 활성화`, 마이크 권한 |
| 연결 질문이 안 들림 | Team Hub questionTts 상태, `ELEVENLABS_VOICE_ID`, asset URL의 LAN 접근 |
| 질문이 수락 후에도 재생 | `상대 참가` 로그와 LiveKit participant 연결 여부 |
| Egress 한쪽 없음 | 두 track publish 로그, LiveKit webhook, Egress worker 로그 |
| raw PCM 업로드 실패 | 부모 `분석 PCM 업로드 완료`, `S3_PUBLIC_ENDPOINT_URL`, 9000 포트 |
| STT에 한 화자만 있음 | 해당 기기 발화 길이/볼륨과 두 Egress object의 크기 |
| `ANALYSIS_EXCLUDED` | 부모 실제 발화가 `PARENT_MIN_SPEECH_SECONDS`보다 짧음 |
| 지표 `UNMEASURABLE` | 출력 JSON의 reason과 `backend/docs/acoustic-design.md` 품질 게이트 |

마지막으로 foreground↔foreground 한 번, 부모 background/잠금 상태 한 번을 각각 통과시키고
두 결과 JSON과 두 기기 화면 녹화를 해커톤 증빙으로 남긴다.
