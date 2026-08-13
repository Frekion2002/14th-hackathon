# 콜록(Collog) 개발 HANDOFF

마지막 갱신: 2026-08-13 (Asia/Seoul)

이 문서는 콜록 개발의 단일 인수인계 기준이다. 구현, 계약, 검증 결과, 미완료 항목이 바뀌면
코드와 같은 커밋에서 반드시 이 문서를 갱신한다. 비밀키와 실제 건강정보는 기록하지 않는다.

## 0. 팀원·AI 공통 작업 규칙

이 저장소에서 작업하는 사람과 AI는 다른 대화 기록을 전제로 삼지 않는다. `HANDOFF.md`만
읽어도 지금까지의 결정, 구현, 검증, 한계와 다음 작업을 복원할 수 있어야 한다.

작업 시작:

1. **매 턴 어떤 파일도 읽거나 수정하기 전에** `git status -sb`와 `git fetch origin main`을
   실행하고 `git rev-list --count HEAD..origin/main`으로 새 push 여부를 확인한다.
2. 원격이 앞서 있고 working tree가 깨끗하면 `git pull --ff-only`로 최신 `main`을 받는다.
   미커밋 변경이 있으면 pull/덮어쓰기를 하지 말고 충돌 가능성을 먼저 보고한다.
3. 이 문서를 처음부터 끝까지 읽고 관련 코드와 테스트를 확인한다.
4. 이미 완료된 기능을 다시 만들지 않고, `의도적으로 미완료`와 `다음 작업 우선순위`를 기준으로
   작업 범위를 정한다.

작업 종료:

1. 변경한 코드의 lint/test/build를 실행한다.
2. 이 문서의 구현 상태, 파일 역할, 환경변수, 검증 결과, 미완료 항목, 다음 작업, 변경 이력 중
   영향받은 내용을 갱신한다.
3. 새 파일을 만들었으면 `파일별 역할` 표에 반드시 추가한다.
4. API/데이터 흐름/보안 규칙을 바꿨으면 해당 설명과 테스트 결과를 함께 수정한다.
5. 코드와 `HANDOFF.md`를 같은 커밋에 넣고 push한다. 문서만 뒤늦게 맞추는 상태를 만들지 않는다.
6. push 전에 `git diff --check`, secret scan, `git status`를 확인한다.

충돌 또는 불명확한 상태:

- 다른 팀원의 미커밋 파일을 삭제·덮어쓰거나 임의로 되돌리지 않는다.
- 건강 신호의 의미, 개인정보 처리, 외부 API 선택처럼 제품 결정이 필요한 부분은 추측으로
  확정하지 않고 `의도적으로 미완료`에 조건과 질문을 기록한다.
- 실제 키, `.p8`, 토큰, 전화번호, 건강정보를 문서·코드·테스트 fixture에 커밋하지 않는다.

## 1. 우리가 만드는 것

콜록은 자녀와 부모의 일상적인 통화를 self-hosted LiveKit VoIP로 연결하고, 부모의 사전 동의가
있는 통화만 분석해 개인 내 건강 변화 기록으로 만드는 iOS 우선 앱이다.

핵심은 진단이 아니라 변화 관찰이다.

- 질환 프로필을 바탕으로 다음 통화 질문을 제안한다.
- 부모/자녀 음성을 분리해 Deepgram Nova-3 한국어 STT를 수행한다.
- Gemini가 직접 언급된 증상·복약·활동·수면만 구조화한다.
- 발화 속도, 휴지 비율, 기본주파수 변동, 기침 이벤트를 개인의 같은 시간대 기준선과 비교한다.
- 원본 오디오는 처리 직후 폐기하고 구조화 결과와 특징값만 보관한다.
- 부모와 자녀가 리포트와 가족 공유 범위를 확인할 수 있다.

제품의 절대 금지선은 질환 진단, 위험군 라벨, 응급도 판단, 치료 지시를 모델 출력으로 만드는
것이다. 현재 LLM 시스템 지시와 응답 schema도 이 원칙에 맞춰져 있다.

## 2. 확정된 기술 전제

| 영역 | 결정 |
|---|---|
| 클라이언트 | Swift 네이티브, iOS 우선 |
| 수신 통화 | APNs VoIP push → PushKit → CallKit |
| 미디어 | LiveKit Cloud가 아닌 self-hosted LiveKit Server |
| 녹음 | LiveKit Track Egress로 부모/자녀 Opus audio track 분리 |
| 분석용 PCM | LiveKit `LocalAudioTrack.add(audioRenderer:)`의 동일 캡처 스트림 |
| API | Python 3.12, FastAPI, async SQLAlchemy |
| DB | 로컬 SQLite, 전체 스택 PostgreSQL |
| 오디오 저장 | 로컬 또는 S3 호환 MinIO |
| STT | Deepgram API, `nova-3`, `language=ko` |
| LLM | Gemini API structured output, 기본 `gemini-3.6-flash` |
| 연결 질문 TTS | Deepgram은 한국어 TTS 미지원. iOS `AVSpeechSynthesizer(ko-KR)` 로컬 재생 |
| 음향 분석 | Deepgram word timing + `librosa.pyin` + versioned transient 후보 detector |
| 배포 스택 | Docker Compose: backend/Postgres/Redis/MinIO/LiveKit/Egress |

## 3. 현재 구현 상태

### 기능 트랙별 판정

| 트랙 | 판정 | 현재 상태 |
|---|---|---|
| AI-1 Deepgram STT | 연동·실호출 검증 완료 | Nova-3 한국어 요청/응답 정규화 완료. 합성 한국어와 실제 Track Egress OGG를 API로 전사해 E2E 성공 |
| AI-1 LLM 항목 추출(P0-5) | 구현·실호출 검증 완료 | 부모-only segment JSON, polarity/evidence, grounding validator. 실제 처리 7건은 7/7; 나머지 33건은 free-tier quota로 미평가 |
| AI-1 되묻는 표현 탐지 | 구현 완료 | 부모 utterance 한국어 규칙/제외, 3초 병합, rule version, 분당 빈도, transcript/report API |
| AI-2 음향 지표 4종(P0-16) | hackathon prototype 완료 | word timing 속도/휴지, PCM pYIN F0, `transient-heuristic-v1` 기침 후보. labeled validation은 남음 |
| AI-2 기준선·robust Z(P0-14/P0-6) | 구현·fixture 검증 완료 | ISO calendar-week median, 4개 주, 현재값 제외, MAD=0 UNSCORABLE, 결측 주 연속 중단 |
| 백엔드 P0 API | prototype 완료 | 인증·초대·동의·통화·LiveKit·리포트·정리 loop 구현. 운영용 SMS/worker/migration/실배포 검증은 별도 |

백엔드/AI 해커톤 prototype의 미구현 코드는 크게 줄었다. 남은 핵심은 기침 후보 detector의
labeled precision 검증, Swift 앱 구현, APNs/실제 iPhone 양단 통화와 PCM E2E다. 현재 음향값은
fixture에서 실제 계산되고 기준선까지 흐르지만 기침 수치를 의료 검증값으로 소개하면 안 된다.

### 완료

- 원본 명세의 27 paths / 28 operations API 계약
- 개발 OTP와 JWT 인증, 부모 초대, 가족 구성원, append-only 동의, 질환 프로필
- 질환별 오늘의 질문 생성과 최근 질문 중복 회피
- 통화 생성/수락/거절/종료 state flow와 KST time-slot 태깅
- self-hosted LiveKit room/token, 부모·자녀 Track Egress, webhook 서명 검증
- S3/MinIO presigned upload와 로컬 signed upload fallback
- Egress와 분석용 PCM 도착을 모두 기다리는 처리 파이프라인
- Deepgram Nova-3 한국어 STT adapter, utterance/word timing과 segment ID 보존
- Gemini parent-only fact/polarity/evidence JSON, category grounding validator, key header/redaction
- 40개 더미 prompt eval suite와 실제 모델 분할 실행 스크립트
- 한국어 되묻기 규칙·제외·3초 병합, 새 event table과 transcript/report 집계
- 실제 16-bit PCM loader/품질 gate, speech rate/pause/pYIN F0/기침 후보 4종 계산
- 부모 발화 20초 미만 분석 제외
- 성공/제외/실패 모두 원본 오디오 즉시 폐기, 실패 잔존 파일 24시간 purge
- calendar-week anchor/rolling baseline, median/MAD robust z, 결측 주 signal, report snapshot
- iOS PushKit용 APNs HTTP/2 provider와 `/devices` idempotent 등록
- PushKit → CallKit → `/accept` → LiveKit iOS 계약 문서
- `/team` 모바일 웹 포털과 `/team/status.json` 비밀값 없는 연동 상태 endpoint
- 연결 대기 질문 `ttsMode=IOS_LOCAL` 계약과 Swift `AVSpeechSynthesizer(ko-KR)` 예제
- APNs 자격증명 점검·실기기 발송 CLI와 sandbox 실기기 CallKit 수신 검증
- iOS 앱 골격. PushKit 토큰 발급, VoIP push 수신, CallKit 수신 화면 표시까지 실기기 동작
- iOS 개발 OTP 로그인, 기기 자동 등록, 가족 목록 발신, 발신·수신 공통 통화 화면
- iOS LiveKit room 접속과 CallKit 세션 활성화 후 마이크 publish, 연결 대기 질문 `ko-KR` TTS

### 의도적으로 미완료

- 기침 후보 detector는 범용 transient heuristic이다. cough 30개/hard negative 30개로
  precision 0.85 이상을 확인하지 않았으며 실패하면 검증된 classifier로 교체한다.
- 전체 40-case 실제 Gemini eval. provider가 처리한 7건은 7/7, 나머지 33건은 free-tier quota로
  요청 자체가 실패해 미평가다.
- SMS OTP 실제 발송 provider. 개발 OTP는 `000000`이다.
- server TTS asset은 없다. 한국어 질문은 의도적으로 iOS 로컬 TTS이며 Swift 구현/실기기
  수락 즉시 중단 검증이 남았다.
- APNs 실기기 E2E는 CallKit 수신 화면 표시까지만 검증했다(2026-08-13, sandbox, HTTP 200).
  실제 통화 orchestration에서 나온 push로 수락→LiveKit 접속까지 이어지는 경로는 아직이다.
- 현재 발급한 `.p8`는 **sandbox 전용**이다. production endpoint는 `BadEnvironmentKeyInToken`
  으로 거부된다. Xcode 직접 설치 빌드 데모에는 문제가 없지만 TestFlight/App Store 빌드로
  넘어가려면 Sandbox & Production key를 새로 발급해야 한다.
- iOS 분석용 PCM writer. `LocalAudioTrack.add(audioRenderer:)`로 48 kHz mono 16-bit WAV를
  만들고 `/raw-audio/upload-url` → PUT → `/raw-audio/complete`로 올리는 경로가 아직 없다.
  따라서 현재 앱만으로는 음향 분석 파이프라인이 돌지 않는다.
- iOS 앱의 초대·동의·질환 프로필 화면. 부모 계정은 백엔드 API로 먼저 만들어야 하며
  앱에서는 로그인과 수신만 가능하다.
- iOS 토큰 저장은 `UserDefaults`다. 실사용 배포 전 Keychain으로 옮긴다.
- iOS 통화 화면의 실기기 검증. 빌드와 계약은 맞췄지만 양단 통화, 오디오 라우팅,
  질문 TTS 즉시 중단은 실제 iPhone 2대로 확인해야 한다.
- APNs 토큰 410/Unregistered 시 DB device 비활성화. 현재 발송 실패를 로그로 남긴다.
- 내구성 있는 작업 큐. 현재 분석 재시도/정리는 FastAPI process의 background task다.

## 4. 전체 통화 흐름

```text
자녀 iOS             Backend               self-hosted LiveKit       부모 iOS
   │ POST /calls        │                          │                    │
   ├───────────────────>│ consent/profile 검증    │                    │
   │                    ├─ create room/token ─────>│                    │
   │<─ token/questions ─┤                          │                    │
   │                    ├─ APNs VoIP push ─────────────────────────────>│
   │ TTS 질문 로컬 재생 │                          │       PushKit→CallKit
   │ join/publish ────────────────────────────────>│                    │
   │                    │<──────── POST /accept ────────────────────────┤
   │                    ├─ parent token + 기존 child track 조회        │
   │                    │<─ signed track_published webhook ─────────────┤
   │                    ├─ per-track OGG Egress ──>│                    │
   │<══════════════════════ WebRTC audio ═══════════════════════════════>│
   │                    │                          │  PCM renderer 기록 │
   │ POST /end ────────>│ stop Egress             │<─ upload PCM ──────┤
   │                    │<─ egress_ended webhook ─┤                    │
   │                    ├─ STT → repeat/LLM → acoustics → report       │
   │                    └─ 모든 원본 오디오 purge                      │
```

APNs payload에는 `callId/callUUID/callerId/callerName/expiresAt`만 넣는다. LiveKit 토큰과
건강정보는 넣지 않는다. 부모의 인증된 `/accept` 응답에서만 부모 LiveKit 토큰을 발급한다.

## 5. 파일별 역할

### 저장소 루트

| 파일 | 역할 |
|---|---|
| `README.md` | 프로젝트 입구와 주요 문서 링크 |
| `HANDOFF.md` | 구현/결정/검증/다음 작업의 단일 기준 문서 |
| `.gitignore` | 키, 로컬 DB·오디오, venv, cache 제외 |

### backend 핵심

| 파일 | 역할 |
|---|---|
| `backend/app/main.py` | FastAPI 생성, lifespan, CORS, 오류 응답, 정리 loop |
| `backend/app/api.py` | 28개 REST endpoint와 통화 orchestration |
| `backend/app/config.py` | 환경변수와 provider 설정 |
| `backend/app/container.py` | DB/storage/LiveKit/STT/LLM/APNs/pipeline 의존성 조립 |
| `backend/app/team_portal.py` | 모바일/WebView 팀 포털 HTML과 비밀값 없는 provider 상태 snapshot |
| `backend/app/database.py` | async engine/session/Base |
| `backend/app/models.py` | 사용자, 가족, 동의, 통화, 오디오, 추출, 기준선, signal, report DB 모델 |
| `backend/app/schemas.py` | camelCase API request/response와 Gemini 추출 schema |
| `backend/app/security.py` | OTP hash, JWT 발급/인증, role 검사 |

### backend provider 및 도메인 서비스

| 파일 | 역할 |
|---|---|
| `services/livekit.py` | self-host LiveKit room/token/audio-track 조회/Track Egress/webhook adapter와 mock |
| `services/notifications.py` | APNs ES256 provider JWT와 HTTP/2 VoIP push, mock/disabled adapter |
| `services/storage.py` | 로컬/S3 저장, presigned upload/read/delete |
| `services/deepgram.py` | Nova-3 STT와 utterance/word timing/segment 정규화 |
| `services/gemini.py` | 부모-only fact/polarity/evidence output와 semantic validator |
| `services/repeat_detector.py` | 설명 가능한 한국어 되묻기 규칙·제외·3초 event 병합 |
| `services/acoustics.py` | PCM loader/품질 gate/속도/휴지/pYIN F0/transient 기침 후보 분석 |
| `services/pipeline.py` | 입력 대기→STT→LLM→음향→signal→purge orchestration |
| `services/signals.py` | 주별 anchor/rolling 기준선, MAD 비교, 결측 주 연속 signal 계산 |
| `services/reports.py` | 주간/월간 report와 되묻기 관찰 snapshot 생성 |
| `services/questions.py` | 질환별 질문 pool, 선택, iOS local TTS mode |
| `services/domain.py` | 가족 접근, 동의, 초대 상태 공통 규칙 |
| `services/http.py` | Deepgram/Gemini transient retry helper |

### 배포·문서·테스트

| 파일 | 역할 |
|---|---|
| `backend/docker-compose.yml` | 전체 self-hosted 개발 스택 |
| `backend/deploy/livekit.yaml` | LiveKit/Redis/webhook/port 설정 |
| `backend/deploy/egress.yaml` | Egress worker/MinIO 설정 |
| `backend/Dockerfile` | API container image |
| `backend/.env.example` | 비밀값 없는 환경변수 template |
| `backend/docs/ios-call-flow.md` | Swift PushKit/CallKit/LiveKit/PCM 구현 계약 |
| `backend/docs/ai-transcript-design.md` | LLM 위치/prompt v2/eval과 되묻기 규칙 detector 설계 |
| `backend/docs/acoustic-design.md` | 음향 4종 정의, 품질 gate, model, worker와 검증 기준 |
| `backend/evals/extraction_cases.json` | parent/child/부정/정정/injection 40개 더미 LLM fixture |
| `backend/scripts/evaluate_extraction.py` | mock/Gemini fixture 평가, 분할/지연 실행 CLI |
| `backend/scripts/check_apns.py` | APNs 자격증명 점검과 실기기 VoIP push 발송 CLI |
| `backend/tests/test_api_flow.py` | 온보딩부터 분석·폐기·리포트까지 E2E API test |
| `backend/tests/test_providers.py` | Deepgram/Gemini/APNs provider unit test |
| `backend/tests/test_ai_pipeline.py` | prompt/repeat/acoustic/calendar-week deterministic test |
| `backend/tests/conftest.py` | 격리 SQLite와 mock provider test app fixture |
| `backend/pyproject.toml` | Python 의존성, ruff/pytest/build 설정 |
| `backend/uv.lock` | 재현 가능한 dependency lock |

### iOS 앱

| 파일 | 역할 |
|---|---|
| `ios/Collog.xcodeproj` | Xcode project. Bundle ID `com.Collog`, deployment target iOS 26.5, LiveKit SPM |
| `ios/Collog/CollogApp.swift` | `AppDelegate`로 실행 초기 PushKit/APNs 등록과 remote token 수신 |
| `ios/Collog/VoipCallCenter.swift` | PushKit 수신, CallKit 발신/수신 action, LiveKit room 접속과 마이크 publish |
| `ios/Collog/CollogAPI.swift` | OTP/기기/가족/통화 REST client와 서버 오류 message 파싱 |
| `ios/Collog/AppSession.swift` | 로그인 세션·가족 구성원 상태. 토큰과 backend URL을 UserDefaults에 보관 |
| `ios/Collog/RingingQuestionSpeaker.swift` | 연결 대기 질문의 `ko-KR` 로컬 TTS 재생/즉시 중단 |
| `ios/Collog/ContentView.swift` | 로그인 분기, 홈(가족 목록·발신 버튼), 개발용 토큰 확인 섹션 |
| `ios/Collog/LoginView.swift` | 개발 OTP 로그인과 backend base URL 입력 |
| `ios/Collog/CallView.swift` | 발신·수신 공통 통화 화면. 오늘의 질문과 종료 버튼 |
| `ios/Collog/Collog.entitlements` | `aps-environment` push entitlement |
| `ios/Collog/Info.plist` | `UIBackgroundModes` = `voip`, `audio`와 마이크 사용 설명 |

발신도 CallKit `CXStartCallAction`을 거친다. 그래야 `didActivate`에서 오디오 세션을 받는
경로가 발신·수신 모두 같아진다. LiveKit `isAutomaticConfigurationEnabled`는 꺼져 있고
엔진은 `.none`으로 시작하므로, CallKit이 세션을 활성화하기 전에는 오디오 장치를 잡지 않는다.
room 접속과 마이크 publish는 분리되어 있고 publish는 `didActivate` 이후에만 실행한다.

`project.pbxproj`에 `DEVELOPMENT_TEAM`이 고정되어 있다. 같은 Apple Developer 팀에 초대되지
않은 팀원은 Signing & Capabilities에서 자기 팀으로 바꿔 빌드하고 그 변경은 커밋하지 않는다.
Xcode가 만드는 `ios/.git`은 제거했다. 다시 생기면 저장소가 iOS 소스 대신 submodule 링크만
기록하므로 clone한 팀원에게 빈 `ios/`가 전달된다.

## 6. 실행과 검증

API만 실행:

```bash
cd backend
cp .env.example .env
uv sync
uv run uvicorn app.main:app --reload --port 8080
```

검증:

```bash
cd backend
uv run ruff check .
uv run pytest -q
uv build
docker compose config --quiet
```

2026-08-11 마지막 검증 결과:

- `uv run ruff check .`: 통과
- `uv run pytest -q`: 38 tests 통과, FastAPI TestClient의 upstream deprecation warning 1개
- `uv build`: wheel/sdist 생성 성공
- generated OpenAPI: 27 paths / 28 operations
- `docker-compose.yml`, `deploy/livekit.yaml`, `deploy/egress.yaml`: YAML parse 통과
- Docker Compose 5.4.0 + Colima arm64에서 Postgres/Redis/MinIO/LiveKit/Egress/backend 전체
  stack을 새 librosa/numpy image로 재빌드·기동하고 health/container import 확인
- 기존 PostgreSQL volume에 새 `repeat_events`, `extraction_evidence`,
  `acoustic_analysis_runs` table 자동 생성 확인
- Deepgram 실제 key: macOS 한국어 합성 WAV를 `nova-3`, `language=ko`로 전사 성공
- Gemini 실제 key: `gemini-3.6-flash` structured JSON 추출 성공
- Gemini prompt v2 실제 더미 중 provider 처리 7건은 7/7. 나머지 33건은 13초 간격에도
  free-tier quota로 요청 실패하여 전체 40건 점수로 기록하지 않음
- 동일 40-case suite의 deterministic mock regression은 40/40 통과
- 실제 iOS 형식 48 kHz PCM resample/sine/known pause fixture에서 음향 4종 OK, 16 kHz 분리
  transient 2개를 기침 후보 2개로 계산. invalid WAV/sample-rate/MAD=0/결측 주 test 통과
- 실제 통합 smoke: LiveKit CLI로 자녀 30.4초/부모 42.4초 Opus track publish → 분리 Track
  Egress → MinIO → Deepgram(부모 발화 42초, 23 segments) → Gemini(4개 항목 모두 존재) →
  `ANALYZED` → 원본 3개 asset purge까지 성공
- `/team` Docker HTML 렌더와 `/team/status.json`을 localhost 및 LAN 주소에서 확인. 실제 key는
  노출하지 않고 provider별 configured boolean만 반환

현재 이 Mac에는 Homebrew `docker-compose 5.4.0`, `docker-buildx 0.36.1`,
`livekit-cli 2.18.2`가 설치되어 있고 `~/.docker/config.json`의 `cliPluginsExtraDirs`가
`/opt/homebrew/lib/docker/cli-plugins`를 가리킨다. 이는 machine-local 설정이라 Git에는 없다.
전체 stack은 `backend/`에서 실행 중이다. 상태는 `docker compose ps`, 중지는
`docker compose down`으로 수행하되 DB/MinIO volume을 보존하려면 `-v`를 붙이지 않는다.

Gemini thinking-capable Flash 모델은 내부 추론 토큰도 output budget을 사용한다. 500으로 두면
짧은 JSON도 `MAX_TOKENS`로 잘렸기 때문에 기본 `GEMINI_MAX_OUTPUT_TOKENS=2048`을 사용하고,
`finishReason != STOP` 응답은 불완전 JSON으로 파싱하지 않고 명시적으로 실패시킨다.
API key는 query string이 아니라 `x-goog-api-key` header로 보내 exception URL/로그 노출을 막고,
legacy query-key 형태의 예외 문자열도 redaction한다.

화자 분리 OGG는 반드시 Track Egress로 저장한다. Participant Egress는 오디오·비디오
transcode 경로여서 이 stack에서 OGG와 호환되지 않았다. `/accept`는 이미 publish된 자녀
microphone track을 조회하고, 이후 부모 track은 `track_published` webhook에서 시작한다.

Swagger는 `http://localhost:8080/docs`, health는 `GET /v1/health`다.
팀 포털은 `http://<backend-host>:8080/team`, machine-readable 상태는
`GET /team/status.json`이다. Swift에서는 같은 URL을 `WKWebView` 최상위 navigation으로 열 수
있다. 포털은 키 값이 아닌 configured boolean만 표시하지만, 인터넷에 직접 노출하는 production
환경에서는 `TEAM_PORTAL_ENABLED=false`로 끄거나 인증/TLS 앞단을 둔다.

전체 스택은 `.env`에 Deepgram/Gemini 키와 iPhone에서 접근 가능한 LAN 주소를 넣은 뒤
`docker compose up --build`로 시작한다. APNs는 선택 사항이며 `.p8`를 절대 커밋하지 않는다.

## 7. 보안·데이터 불변조건

- 최신 부모 동의가 `GRANTED`가 아니면 Egress와 PCM 업로드를 시작하지 않는다.
- 동의 이력은 overwrite하지 않고 append-only로 쌓는다.
- 부모 발화 20초 미만은 LLM/음향 변화 분석에서 제외한다.
- 원본 오디오는 분석 성공 여부와 관계없이 폐기한다.
- 저장 가능한 것은 구조화 텍스트, 파생 특징값, 리포트다.
- Gemini 무료 티어에는 해커톤 더미 데이터만 보낸다.
- LLM은 대화에 없는 원인, 질환, 위험도, 응급도, 치료를 생성하지 않는다.
- 비교는 인구집단 진단 cutoff가 아니라 같은 사람·같은 time slot의 이전 기록을 기준으로 한다.
- Apple `.p8`, Deepgram/Gemini/API/JWT secret은 Git에 넣지 않는다.

### 자격증명 구분

| 자격증명 | 어디서 얻는가 | 해커톤 필요 여부 | 용도 |
|---|---|---|---|
| `DEEPGRAM_API_KEY` | Deepgram Console 발급 | 필수 | Nova-3 한국어 STT |
| `GEMINI_API_KEY` | Google AI Studio 발급 | 필수 | 구조화 LLM. OpenAI key와 동시에 필요하지 않음 |
| `LIVEKIT_API_KEY/SECRET` | 우리가 직접 강한 난수로 생성 | 필수 | self-hosted room token, server API, Egress, webhook 서명 |
| `JWT_SECRET` | 우리가 직접 강한 난수로 생성 | 필수 | 콜록 사용자 인증 JWT |
| APNs `.p8`/Key ID/Team ID/Bundle ID | Apple Developer 발급·확인 | 실기기 백그라운드 수신 시 필수 | PushKit VoIP push |
| MinIO access key/secret | 우리가 직접 생성 | Egress 녹음 시 필수 | self-hosted S3 호환 오디오 저장 |

최소 foreground 데모에서 외부 업체로부터 받을 것은 Deepgram key와 Gemini key 두 개다.
LiveKit key/secret은 LiveKit Cloud에서 받지 않는다. 실제 iOS PushKit 수신까지 시연하면 Apple
APNs 자격증명이 추가된다. Gemini 무료 tier에는 제품 개선 데이터 사용 조건이 있으므로 실제
건강정보가 아닌 더미 데이터만 사용한다.

Deepgram에는 Aura TTS API가 있지만 2026-08-11 공식 지원 언어에 한국어가 없다. 따라서 기존
Deepgram key로 콜록 질문의 한국어 TTS를 만들 수 없고 추가 Deepgram TTS key도 받지 않는다.
현재 iOS 내장 `ko-KR` voice를 사용한다.

`JWT_SECRET`은 클라이언트용 값이 아니다. Swift/iOS·프론트엔드 팀원에게 전달하지 않는다.
하나의 공용 백엔드만 사용하면 그 배포 환경에만 보관한다. 팀원이 각자 독립 로컬 백엔드를
실행하면 각자 다른 secret을 써도 된다. 같은 도메인에서 여러 backend replica가 동일 로그인
토큰을 검증해야 할 때만 모든 replica에 같은 secret을 secret manager로 배포한다. 이 값을
변경하면 이전에 발급한 access/refresh token은 모두 무효화된다.

### 팀 공유 기준

`.env` 파일 전체나 비밀값을 Git·메신저로 전달하지 않는다. 팀원 역할별 전달 범위는 다음과
같다.

| 대상 | 전달할 값 | 전달하지 않을 값 |
|---|---|---|
| Swift/iOS 팀 | 공용 Backend base URL. `livekitUrl`과 room `accessToken`은 통화 API 응답으로 받음 | Deepgram/Gemini key, `JWT_SECRET`, `LIVEKIT_API_SECRET`, MinIO secret, APNs `.p8` |
| 공용 Backend 운영자 | 모든 서버 secret을 배포 환경의 secret manager에 설정 | Swift 소스·Git·팀 포털에 raw secret 노출 금지 |
| 독립 로컬 Backend 실행자 | 본인 Deepgram/Gemini key 또는 안전하게 전달받은 개발용 key, 본인이 생성한 `JWT_SECRET`; LiveKit/MinIO 값은 자신의 서버 설정과 일치시킴 | 다른 개발자의 개인 `.env` 전체를 복사할 필요 없음 |
| APNs 담당자 | 비밀이 아닌 Team ID, Key ID, Bundle ID, 환경을 서버 담당자와 공유; `.p8`은 서버 운영자에게만 보안 채널로 전달 | `.p8`을 Git·일반 메신저·팀 전체에 배포 금지 |

LAN 데모에서 팀에 공개해도 되는 값은 `PUBLIC_BASE_URL`, `LIVEKIT_URL`,
`S3_PUBLIC_ENDPOINT_URL` 같은 접속 주소다. 다만 iOS 앱은 실제로 공용 Backend base URL만
고정하면 되고, LiveKit URL과 토큰 및 PCM presigned URL은 Backend 응답으로 받는다. TTS는
iOS 로컬 `AVSpeechSynthesizer`이므로 별도 TTS key가 없다.

#### pull 후 팀원 PC에서 전체 스택을 실행하는 최소 `.env`

팀원이 `backend/`에서 `docker compose up --build`를 실행해 실제 STT/LLM까지 재현하려면
저장소에 포함되지 않은 아래 값을 전달해야 한다.

```dotenv
DEEPGRAM_API_KEY=<팀 개발용 실제 값>
GEMINI_API_KEY=<팀 개발용 실제 값>
JWT_SECRET=<팀 공용 값 또는 각자 생성한 32자 이상 값>
MOCK_EXTERNAL_SERVICES=false
GEMINI_MODEL=gemini-3.6-flash
DEEPGRAM_MODEL=nova-3

# Mac 자체에서만 호출하면 localhost, 실제 iPhone이면 각 팀원 Mac의 LAN IP로 변경
PUBLIC_BASE_URL=http://<HOST>:8080
LIVEKIT_URL=ws://<HOST>:7880
S3_PUBLIC_ENDPOINT_URL=http://<HOST>:9000
```

팀원에게 가장 단순하게 전달하는 방법은 위 내용이 들어간 `backend/.env`를 별도로 전달하고,
각 팀원이 `<HOST>` 세 곳만 자기 환경에 맞게 바꾸는 것이다. Mac/Simulator만 사용하면
`<HOST>`는 `localhost`, 같은 Wi-Fi의 실제 iPhone이면 해당 Mac의 LAN IP다. 독립 로컬 DB를
쓰므로 `JWT_SECRET`은 같아도 되고 달라도 실행에는 문제가 없다.

이 저장소는 public이므로 실제 key가 든 `.env`를 커밋해서 `pull`만으로 provider 호출까지
동작하게 만들면 안 된다. 실제 API를 쓰는 로컬 실행은 `.env`를 저장소 밖에서 한 번 별도
전달하거나, 모든 팀원이 하나의 공용 Backend를 사용해야 한다. GitHub Actions secret은 CI에는
주입할 수 있지만 팀원의 로컬 `git pull`에는 전달되지 않는다. key를 실수로 public commit에
넣었다면 파일을 나중에 삭제하는 것만으로는 부족하며 해당 key를 즉시 폐기·재발급한다.

현재 Docker Compose와 `deploy/` 설정에는 서로 일치하는 개발용 LiveKit key/secret, MinIO
access key/secret, PostgreSQL 계정, Redis 설정이 이미 포함되어 있다. 따라서 저장소 그대로
실행하는 팀원에게 이 값들을 `.env`로 또 전달할 필요는 없다. 개발용 기본값을 변경할 때에만
`docker-compose.yml`, `deploy/livekit.yaml`, `deploy/egress.yaml`의 값을 모두 함께 맞춘다.

APNs 없이도 foreground 통화와 STT/LLM/음향 파이프라인은 실행된다. 실제 iPhone이 앱 종료·
백그라운드 상태에서도 전화를 받게 하려면 그때 추가로 `APNS_VOIP_ENABLED=true`, Team ID,
Key ID, Bundle ID, environment, `.p8` 파일 경로를 설정하고 실제 `.p8` 파일도 전달해야 한다.

APNs 작업은 단순 Apple ID 보유자가 아니라 Apple Developer Program 팀의 Account Holder 또는
Admin에게 요청한다. 요청 범위는 다음과 같다.

1. 콜록의 explicit Bundle ID를 확정하고 해당 App ID에 Push Notifications capability를 켠다.
2. 기존 APNs-enabled signing key를 안전하게 재사용하거나 새 key를 생성한다. Configure Key의
   Environment와 Key Restriction은 저장 후 변경할 수 없다. Bundle ID가 확정되기 전이라면
   Topic Scoped 대신 Team Scoped를 쓴다. APNs key는 팀당 개수 제한이 있어 잘못 묶인 key를
   버리는 비용이 크다. Environment는 TestFlight 전환까지 고려해 Sandbox & Production을 쓴다.
3. 서버 담당자에게 Team ID, Key ID, Bundle ID, sandbox/production 환경을 알려준다.
4. `.p8` 파일은 한 번만 다운로드할 수 있으므로 Git·메신저에 올리지 않고 secret manager 또는
   안전한 오프라인 경로로 서버에 전달한다.
5. Swift target도 같은 Team/Bundle ID로 서명하고 Xcode에서 Push Notifications와 필요한
   background mode를 활성화한다.

VoIP Services Certificate(`.p12`)는 만들지 않는다. 토큰 방식 `.p8` 하나로 sandbox와
production을 모두 처리하며 provider 코드도 `.p8` ES256 JWT만 사용한다. 값을 받으면 Swift 앱
없이도 `uv run python -m scripts.check_apns`로 자격증명을 먼저 검증한다. 더미 토큰에 대한
`BadDeviceToken` 응답이 성공 신호이고, `InvalidProviderToken`은 `.p8`/Key ID/Team ID 조합,
`BadTopic`·`TopicDisallowed`는 Bundle ID 또는 App ID capability 문제다. Xcode 직접 설치
빌드의 토큰은 sandbox에서만, TestFlight/App Store 빌드의 토큰은 production에서만 유효하다.

## 8. 다음 작업 우선순위

1. 실제 cough 30개/hard-negative 30개로 `transient-heuristic-v1`을 검증한다. precision 0.85
   미달이면 YAMNet/검증된 cough classifier로 교체한다.
2. 40-case Gemini eval을 `--start/--limit/--delay`로 quota-safe하게 완료하고 실패 fixture를
   prompt/schema에 반영한다.
3. iOS 앱에 LiveKit Swift SDK를 SPM으로 추가하고 `ios-call-flow.md` 기준으로
   `connectMedia`/오디오 세션 handler, 16-bit PCM writer, 로컬 `ko-KR` TTS를 채운다.
   로그인 흐름을 붙여 `/devices` 자동 등록과 `/accept`가 동작하게 한다.
4. 실제 iPhone 양단 통화로 Track Egress와 네트워크 전환까지 E2E 검증한다. APNs는
   sandbox 실기기 CallKit 수신까지 2026-08-13에 검증했다.
5. 실제 iPhone 20~30통으로 PCM 품질 gate/F0/기침 threshold와 time-slot 분포를 freeze한다.
6. background task를 Redis 기반 worker로 분리하고 idempotency/재시도를 보강한다.
7. SMS OTP와 일반 APNs 알림 provider를 붙인다.

해커톤 핵심 demo 완료 기준은 1~4다. backend/AI 코드는 prototype 수준으로 구현됐고, 이제
주된 blocker는 실제 label 음원과 Swift/APNs/iPhone이다. 5는 신뢰도 보강, 6~7과 DB
migration/TLS/secret manager는 production 전환 작업이다.

다음 AI는 구현 전에 반드시 이 문서와 `backend/README.md`, 관련 service/test를 먼저 읽는다.
API를 바꿀 때에는 기존 camelCase 계약과 테스트를 유지하고, 판단 불가능한 건강 지표를 임의의
숫자로 채우지 않는다.

## 9. 변경 이력

- 2026-08-11: FastAPI/LiveKit/Deepgram/Gemini/기준선·리포트 전체 P0 골격 구현.
- 2026-08-11: LiveKit Cloud 대신 Server/Egress/Redis/MinIO self-hosted stack 확정.
- 2026-08-11: 클라이언트를 Swift 네이티브 iOS 우선으로 확정.
- 2026-08-11: APNs VoIP push provider와 PushKit/CallKit/LiveKit 통화 계약 추가.
- 2026-08-11: 공식 저장소를 `Frekion2002/14th-hackathon`으로 전환하고 HANDOFF 관리 시작.
- 2026-08-11: 외부 발급 키와 self-hosted 내부 secret을 구분한 자격증명 표 추가.
- 2026-08-11: 팀원·AI의 pull/read/verify/update/commit/push HANDOFF 운영 규칙 확정.
- 2026-08-11: Apple Developer Account Holder/Admin에게 요청할 APNs 준비 절차 추가.
- 2026-08-11: AI-1/AI-2/백엔드 완료 여부를 재감사하고 되묻기·음향·주 단위 signal 누락을 명시.
- 2026-08-11: Colima에서 self-hosted 7-service stack을 실제 기동하고 Deepgram/Gemini 실호출 검증.
- 2026-08-11: Gemini 500-token JSON truncation을 발견해 2,048 token 설정과 finishReason 검증 추가.
- 2026-08-11: Participant Egress+OGG 통합 오류를 발견해 audio Track Egress와
  `track_published` webhook orchestration으로 교체.
- 2026-08-11: 두 합성 참가자 통화의 LiveKit→MinIO→Deepgram→Gemini→purge 실제 E2E 성공.
- 2026-08-11: 매 턴 시작 전 `fetch`/원격 commit 비교를 강제하는 협업 규칙 추가.
- 2026-08-11: `/team` WebView 대응 팀 포털과 비밀값 없는 `/team/status.json` 추가.
- 2026-08-11: LLM prompt/eval·되묻기 규칙 detector와 AI-2 4종 음향 지표 설계 확정.
- 2026-08-11: prompt v2 parent evidence/polarity/grounding validator와 40-case eval suite 구현.
- 2026-08-11: Gemini key를 query에서 header로 이동하고 exception redaction 추가.
- 2026-08-11: 되묻기 규칙 detector/event/API/report와 Deepgram word timing 보존 구현.
- 2026-08-11: PCM AI-2 4종 prototype, analyzer version 저장, calendar-week baseline 수정.
- 2026-08-11: Deepgram Aura 한국어 TTS 미지원을 확인하고 iOS local `ko-KR` TTS로 확정.
- 2026-08-13: APNs 자격증명 점검 CLI `scripts/check_apns.py`와 Apple Developer/Xcode PushKit 설정 절차 추가.
- 2026-08-13: 실제 Apple 자격증명으로 APNs sandbox 자격증명 점검 통과. 발급한 key는 sandbox 전용.
- 2026-08-13: iOS Xcode project를 `ios/`로 추가하고 PushKit→CallKit 실기기 수신을 검증.
- 2026-08-13: iOS 로그인·발신·수신 통화 화면과 LiveKit 연동, 질문 로컬 TTS 구현.
