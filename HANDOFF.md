# 콜록(Collog) 개발 HANDOFF

마지막 갱신: 2026-08-11 (Asia/Seoul)

이 문서는 콜록 개발의 단일 인수인계 기준이다. 구현, 계약, 검증 결과, 미완료 항목이 바뀌면
코드와 같은 커밋에서 반드시 이 문서를 갱신한다. 비밀키와 실제 건강정보는 기록하지 않는다.

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
| 녹음 | LiveKit Participant Egress로 부모/자녀 분리 |
| 분석용 PCM | LiveKit `LocalAudioTrack.add(audioRenderer:)`의 동일 캡처 스트림 |
| API | Python 3.12, FastAPI, async SQLAlchemy |
| DB | 로컬 SQLite, 전체 스택 PostgreSQL |
| 오디오 저장 | 로컬 또는 S3 호환 MinIO |
| STT | Deepgram API, `nova-3`, `language=ko` |
| LLM | Gemini API structured output, 기본 `gemini-3.6-flash` |
| 배포 스택 | Docker Compose: backend/Postgres/Redis/MinIO/LiveKit/Egress |

## 3. 현재 구현 상태

### 완료

- 원본 명세의 27 paths / 28 operations API 계약
- 개발 OTP와 JWT 인증, 부모 초대, 가족 구성원, append-only 동의, 질환 프로필
- 질환별 오늘의 질문 생성과 최근 질문 중복 회피
- 통화 생성/수락/거절/종료 state flow와 KST time-slot 태깅
- self-hosted LiveKit room/token, 부모·자녀 Participant Egress, webhook 서명 검증
- S3/MinIO presigned upload와 로컬 signed upload fallback
- Egress와 분석용 PCM 도착을 모두 기다리는 처리 파이프라인
- Deepgram Nova-3 한국어 STT adapter와 화자별 segment 정규화
- Gemini JSON Schema 추출과 진단/치료 추론 방지 시스템 지시
- 부모 발화 20초 미만 분석 제외
- 성공/제외/실패 모두 원본 오디오 즉시 폐기, 실패 잔존 파일 24시간 purge
- anchor/rolling baseline, median/MAD robust z, 연속 변화 signal, report snapshot
- iOS PushKit용 APNs HTTP/2 provider와 `/devices` idempotent 등록
- PushKit → CallKit → `/accept` → LiveKit iOS 계약 문서

### 의도적으로 미완료

- 음향 분석기의 실제 알고리즘. 현재 4종 지표를 가짜 수치로 채우지 않고
  `UNMEASURABLE / EXTRACTION_ERROR`로 저장한다.
- SMS OTP 실제 발송 provider. 개발 OTP는 `000000`이다.
- 질문 TTS asset 생성. 현재 `ttsAssetUrl`은 `null`이고 iOS 로컬 TTS fallback이 필요하다.
- APNs 실기기 E2E. provider 코드는 구현했지만 Apple 계정 식별자와 `.p8`, 실제 iPhone으로
  검증해야 한다.
- Swift 앱 자체. 현재는 서버 계약과 연동 문서만 있으며 Xcode project는 아직 없다.
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
   │                    ├─ parent token + Egress ─>│                    │
   │<══════════════════════ WebRTC audio ═══════════════════════════════>│
   │                    │                          │  PCM renderer 기록 │
   │ POST /end ────────>│ stop Egress             │<─ upload PCM ──────┤
   │                    │<─ egress_ended webhook ─┤                    │
   │                    ├─ STT → LLM → acoustics → baseline/report     │
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
| `backend/app/database.py` | async engine/session/Base |
| `backend/app/models.py` | 사용자, 가족, 동의, 통화, 오디오, 추출, 기준선, signal, report DB 모델 |
| `backend/app/schemas.py` | camelCase API request/response와 Gemini 추출 schema |
| `backend/app/security.py` | OTP hash, JWT 발급/인증, role 검사 |

### backend provider 및 도메인 서비스

| 파일 | 역할 |
|---|---|
| `services/livekit.py` | self-host LiveKit room/token/Egress/webhook adapter와 mock |
| `services/notifications.py` | APNs ES256 provider JWT와 HTTP/2 VoIP push, mock/disabled adapter |
| `services/storage.py` | 로컬/S3 저장, presigned upload/read/delete |
| `services/deepgram.py` | Nova-3 prerecorded STT 요청과 segment/speech-time 정규화 |
| `services/gemini.py` | JSON Schema 기반 4개 건강 대화 항목 구조화 |
| `services/acoustics.py` | 실제 분석기를 교체할 port와 안전한 unconfigured 구현 |
| `services/pipeline.py` | 입력 대기→STT→LLM→음향→signal→purge orchestration |
| `services/signals.py` | anchor/rolling 기준선, MAD 비교, 연속 signal 계산 |
| `services/reports.py` | 주간/월간 report snapshot 생성 |
| `services/questions.py` | 질환별 질문 pool과 선택 |
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
| `backend/tests/test_api_flow.py` | 온보딩부터 분석·폐기·리포트까지 E2E API test |
| `backend/tests/test_providers.py` | Deepgram/Gemini/APNs provider unit test |
| `backend/tests/conftest.py` | 격리 SQLite와 mock provider test app fixture |
| `backend/pyproject.toml` | Python 의존성, ruff/pytest/build 설정 |
| `backend/uv.lock` | 재현 가능한 dependency lock |

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
- `uv run pytest -q`: 8 tests 통과, FastAPI TestClient의 upstream deprecation warning 1개
- `uv build`: wheel/sdist 생성 성공
- generated OpenAPI: 27 paths / 28 operations
- `docker-compose.yml`, `deploy/livekit.yaml`, `deploy/egress.yaml`: YAML parse 통과
- 현재 작업 머신은 Docker Compose plugin이 없어 실제 stack boot 검증은 하지 못했다.

Swagger는 `http://localhost:8080/docs`, health는 `GET /v1/health`다.

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

## 8. 다음 작업 우선순위

1. APNs provider unit test를 완료하고 실제 Apple sandbox/iPhone E2E를 검증한다.
2. Swift Xcode project가 생기면 `docs/ios-call-flow.md` 기준으로 CallCoordinator를 구현한다.
3. LiveKit renderer PCM sample rate/channel을 실기기에서 측정하고 WAV 변환기를 확정한다.
4. 음향 4종 중 기침 이벤트와 발화 속도부터 검증된 analyzer로 구현한다.
5. background task를 Redis 기반 worker로 분리하고 idempotency/재시도를 보강한다.
6. SMS OTP와 일반 APNs 알림 provider를 붙인다.

다음 AI는 구현 전에 반드시 이 문서와 `backend/README.md`, 관련 service/test를 먼저 읽는다.
API를 바꿀 때에는 기존 camelCase 계약과 테스트를 유지하고, 판단 불가능한 건강 지표를 임의의
숫자로 채우지 않는다.

## 9. 변경 이력

- 2026-08-11: FastAPI/LiveKit/Deepgram/Gemini/기준선·리포트 전체 P0 골격 구현.
- 2026-08-11: LiveKit Cloud 대신 Server/Egress/Redis/MinIO self-hosted stack 확정.
- 2026-08-11: 클라이언트를 Swift 네이티브 iOS 우선으로 확정.
- 2026-08-11: APNs VoIP push provider와 PushKit/CallKit/LiveKit 통화 계약 추가.
- 2026-08-11: 공식 저장소를 `Frekion2002/14th-hackathon`으로 전환하고 HANDOFF 관리 시작.
