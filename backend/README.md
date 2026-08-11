# Collog backend

콜록의 P0 API, self-hosted LiveKit 통화 녹음, Deepgram Nova-3 한국어 STT,
Gemini 건강 대화 구조화 파이프라인이다.

## 구현 범위

- 휴대폰 OTP 인증, 부모 초대, append-only 민감정보 동의, 질환 프로필
- 질환별 오늘의 질문과 통화 시작/수락/거절/종료 API
- self-hosted LiveKit Server와 Track Egress 기반 화자별 Opus/OGG 녹음
- iOS PushKit VoIP 푸시와 CallKit 수신 통화용 APNs provider
- 부모 기기 분석용 PCM 파일의 presigned upload
- Deepgram `nova-3`, `language=ko` 사전 녹음 STT
- Gemini JSON Schema 기반 증상·복약·활동·수면 추출
- 부모 발화 20초 미만 제외, 오디오 분석 직후 폐기, 실패 파일 24시간 내 폐기
- 앵커/롤링 기준선, MAD robust z, 변화 신호, immutable 리포트 스냅샷 API

음향 지표 4종은 API와 파이프라인 경계까지 연결되어 있지만 아직 검증된 분석기가 선택되지
않았다. 임의의 숫자로 개인 기준선을 오염시키지 않도록 현재는 네 지표 모두 명시적인
`UNMEASURABLE / EXTRACTION_ERROR`로 저장한 뒤 원시 음성을 폐기한다.

## 빠른 로컬 실행 — API만

외부 서비스 없이 전체 API 흐름을 확인할 수 있다. 개발 OTP는 `000000`이다.

```bash
cp .env.example .env
uv sync
uv run uvicorn app.main:app --reload --port 8080
```

- Swagger UI: <http://localhost:8080/docs>
- 상태 확인: <http://localhost:8080/v1/health>
- SQLite와 업로드 파일: `.data/`

`MOCK_EXTERNAL_SERVICES=true`에서는 LiveKit, Deepgram, Gemini 호출이 모의 구현으로
대체된다. 운영 또는 통합 테스트에서만 `false`로 둔다.

## self-hosted 전체 스택

Docker Compose는 다음 서비스를 한 번에 실행한다.

```text
앱 ── WebRTC ── LiveKit Server ── Redis
                       │
                  Egress worker ── MinIO
                                      │
백엔드 ── PostgreSQL       Deepgram/Gemini API
   └──── APNs VoIP push ── iOS PushKit/CallKit
```

`.env`에 두 API 키와 기기에서 접근 가능한 주소를 넣는다.

```dotenv
DEEPGRAM_API_KEY=...
GEMINI_API_KEY=...

# 실제 휴대폰이라면 개발 PC의 LAN 주소를 사용한다.
PUBLIC_BASE_URL=http://192.168.0.10:8080
LIVEKIT_URL=ws://192.168.0.10:7880
S3_PUBLIC_ENDPOINT_URL=http://192.168.0.10:9000
```

그다음 실행한다.

```bash
docker compose up --build
```

| 서비스 | 주소 |
|---|---|
| Backend | `http://localhost:8080` |
| LiveKit signaling | `ws://localhost:7880` |
| LiveKit TCP | `localhost:7881` |
| LiveKit UDP | `localhost:7882/udp` |
| MinIO API | `http://localhost:9000` |
| MinIO console | `http://localhost:9001` |

Egress는 LiveKit과 같은 Redis를 사용한다. 통화 수락 시 이미 publish된 자녀의 microphone
track을 조회하고, 수락 뒤 publish되는 부모 track은 서명된 `track_published` 웹훅으로 받아
각각 Opus/OGG Track Egress를 시작한다. `Participant Egress + OGG`는 비디오 transcode 경로와
호환되지 않으므로 사용하지 않는다. Egress 완료 웹훅은 LiveKit JWT 서명을 검증한 뒤에만
파일을 분석 큐에 넣는다.

개발용 LiveKit/MinIO/PostgreSQL 비밀값은 compose 파일에 고정되어 있다. 외부에 노출하는
배포에서는 `deploy/livekit.yaml`, `deploy/egress.yaml`, compose의 모든 비밀값을 교체하고
TLS/TURN을 앞단에 구성해야 한다.

## 분석 순서

1. 자녀가 `POST /calls`를 호출하면 동의 상태를 확인하고 LiveKit 룸과 자녀 토큰을 만든다.
2. 등록된 iOS VoIP 토큰이 있으면 APNs PushKit 푸시로 CallKit 수신 화면을 연다.
3. 부모가 `/calls/{id}/accept`하면 부모 토큰과 녹음 asset을 만들고, 이미 publish된 audio
   track과 이후 `track_published`된 audio track에 각각 Track Egress를 시작한다.
4. 부모 앱은 LiveKit `LocalAudioTrack.add(audioRenderer:)`에서 동일 캡처 스트림의 PCM을
   파일로 기록한다. 별도 `AVAudioEngine`으로 마이크를 두 번 열지 않는다.
5. 통화 종료 후 Egress 웹훅과 분석용 PCM 완료 이벤트를 모두 기다린다.
6. 화자별 OGG를 Deepgram Nova-3 한국어 모델에 보내고 시간순으로 합친다.
7. 부모 발화가 20초 이상이면 Gemini가 네 항목을 JSON으로 추출한다.
8. 음향 분석 포트를 실행하고 기준선·변화 신호·리포트를 갱신한다.
9. 성공·제외·실패 여부와 관계없이 원본 파일을 폐기하고 폐기 시각을 남긴다.

## iOS 수신 통화

클라이언트 전제는 Swift 네이티브, iOS 우선이다. 상세한 PushKit → CallKit → LiveKit 순서와
분석용 PCM 캡처 방식은 [`docs/ios-call-flow.md`](docs/ios-call-flow.md)에 정리했다.

실기기 수신 통화를 켜려면 Apple Developer에서 VoIP Services가 가능한 App ID와 APNs
토큰 키를 준비한 뒤 다음 값을 설정한다.

```dotenv
APNS_VOIP_ENABLED=true
APNS_ENVIRONMENT=sandbox
APNS_TEAM_ID=YOUR_TEAM_ID
APNS_KEY_ID=YOUR_KEY_ID
APNS_BUNDLE_ID=com.example.Collog
APNS_PRIVATE_KEY_PATH=/absolute/or/container/path/AuthKey_XXXX.p8
```

`.p8` 파일은 저장소와 이미지에 넣지 않는다. Docker로 실행할 때에는 별도 secret/bind mount로
컨테이너에 읽기 전용 마운트하고 `APNS_PRIVATE_KEY_PATH`를 컨테이너 내부 경로로 지정한다.
APNs가 꺼져 있거나 부모 기기에 `voipToken`이 없으면 foreground-only 데모 통화는 계속
동작한다.

Gemini는 말하지 않은 원인을 추론하지 않으며 질환명, 위험군 라벨, 응급도, 치료 지시를
생성하지 않도록 시스템 지시와 응답 스키마로 제한한다.

> Gemini 무료 티어는 해커톤의 더미 데이터에만 사용한다. 무료 티어 입력은 Google 제품
> 개선에 사용될 수 있으므로 실제 건강정보를 처리하는 운영 환경에서는 데이터 비학습 조건의
> 유료 계약 또는 별도의 보호된 모델 엔드포인트로 전환해야 한다.

## 검증

```bash
uv run ruff check .
uv run pytest -q
docker compose config --quiet
```

테스트는 초대→동의→질환 프로필→통화→이중 업로드→STT/LLM→폐기→리포트 전체 흐름과
Deepgram 응답 정규화, Gemini 출력 truncation 방지, LiveKit Track Egress 요청·웹훅,
APNs VoIP 요청 헤더·payload를 포함한다.

전체 작업 상태와 파일별 역할, 다음 작업은 [`HANDOFF.md`](../HANDOFF.md)를 기준으로 관리한다.
