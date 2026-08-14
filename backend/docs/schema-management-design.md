# 스키마 관리 설계 — 로컬 가드와 배포 migration

마지막 갱신: 2026-08-14

상태: 설계 승인됨, 구현 전

## 1. 해결하는 문제 두 개

### 1-1. 로컬: 조용히 어긋나는 개발 DB

`app/main.py:25`의 `container.database.create_all()`은 **없는 테이블만 만들고 기존 테이블은
ALTER하지 않는다.** Phase 1이 기존 테이블을 바꾸기 시작하면 조용한 실패가 된다.

| Phase 1 변경 | `create_all()` 동작 |
|---|---|
| `HealthProfile`/`HealthCondition`/`Medication`/`HealthConcern` 신규 | 생성됨 |
| `users.role` 제거·변경 | 무시됨 |
| `consent_records` 철회 컬럼 추가 | 무시됨 |
| `parent_profiles` 제거 | 테이블이 남음 |

가장 나쁜 점은 **앱이 정상 기동한다**는 것이다. 신규 테이블은 만들어지므로 startup은
성공하고, 런타임에 없는 컬럼을 조회할 때 처음 터진다. 팀원은 원인이 코드인지 DB 상태인지
매번 의심해야 한다.

### 1-2. 서버: 2026-08-18부터 지켜야 하는 데이터

2026-08-18에 공용 서버가 생기고, 데모까지 **실기기 통화 기록이 서버에 남아 있어야 한다.**
재생성이 불가능한 데이터가 처음으로 존재하게 되므로, 그 시점부터는 스키마를 바꿀 때
DB를 지울 수 없다.

`scripts/seed_demo_family.py`가 만드는 계정·가족·동의·프로필은 재생성 가능하지만, 실기기
두 대로 실제 통화해서 만든 `calls`/`transcripts`/`acoustic_features`/`reports`는 그렇지 않다.

## 2. 두 축으로 나눈다

두 문제는 요구가 반대다. 로컬은 빠른 폐기가 이득이고, 서버는 보존이 필수다. 하나의
메커니즘으로 둘 다 만족시키려 하면 어느 쪽도 제대로 못 한다.

| | 로컬 개발 (2026-08-14~) | 배포 서버 (2026-08-18~) |
|---|---|---|
| 스키마 주인 | schema guard | **Alembic** |
| `SCHEMA_AUTO_RESET` | `true` | `false` |
| guard 역할 | 필요하면 생성·재생성 | **검증만.** 스키마를 수정하지 않음 |
| 데이터 | 버려도 됨 | **보존 필수** |

계획서(`implementation-plan-v2.md` 98행)의 "schema 변경은 Alembic migration으로 남긴다"는
그대로 유지된다. guard는 그것을 대체하지 않고, migration을 쓸 가치가 없는 로컬 구간만
맡는다.

## 3. 스키마 비교 방식

guard는 **저장된 지문을 쓰지 않는다.** 실제 DB를 reflect해서 모델과 직접 비교한다. 별도
상태 테이블이 필요 없고, "migration을 안 돌렸다" "migration이 중간에 실패했다"를 같은
검사로 잡을 수 있다.

### 3-1. 무엇을 비교하는가

테이블 이름과 **컬럼 이름 집합**만 비교한다. 컬럼 타입은 비교하지 않는다.

reflect된 타입은 dialect마다 다르게 렌더링된다. 예를 들어 모델의 `DateTime(timezone=True)`는
`str()`이 `DATETIME`을 주지만 Postgres에서 reflect하면 `TIMESTAMP WITH TIME ZONE`이 된다.
타입까지 비교하면 정상 상태에서 오탐이 난다.

컬럼 이름만으로도 실제로 앱을 깨뜨리는 경우는 전부 잡힌다.

| 차이 | 런타임 영향 | 검사 대상 |
|---|---|---|
| 모델에 있는 테이블이 DB에 없음 | 즉시 실패 | 예 |
| 모델에 있는 컬럼이 DB에 없음 | 조회 시 실패 | 예 |
| DB에만 있는 테이블·컬럼 | 무해 | 아니오 |
| 타입 변경 | 드묾, dialect 오탐 위험이 더 큼 | 아니오 |

### 3-2. 판정

```
model_shape  = {table: {column names}}   Base.metadata에서
actual_shape = {table: {column names}}   inspect/reflect로
```

| 상태 | 판정 |
|---|---|
| `actual_shape`가 비어 있음 | `FRESH` |
| 모델 테이블이 통째로 없기만 함 (기존 테이블은 온전) | `ADDITIVE` |
| 기존 테이블에 모델 컬럼이 없음 | `DRIFTED` |

`ADDITIVE`와 `DRIFTED`를 나누는 이유는 **로컬 데이터 보존**이다. Phase 2의
`CallParticipant`, Phase 4의 observation, Phase 5의 report snapshot은 전부 신규 테이블
추가이며 기존 데이터를 건드리지 않고 적용할 수 있다. 이 둘을 구분하지 않고 하나의 전체
스키마 해시로 판정하면, 팀원이 Phase 2를 pull할 때마다 안전하게 적용 가능한 변경 때문에
로컬 DB가 통째로 날아가고 seed를 다시 돌려야 한다.

서버에서는 두 판정 모두 기동 거부로 같게 다룬다. 3-3의 소유권 규칙 때문이다.

### 3-3. 판정별 동작

| 판정 | `SCHEMA_AUTO_RESET=true` (로컬) | `SCHEMA_AUTO_RESET=false` (서버) |
|---|---|---|
| 일치 | 아무것도 안 함 | 아무것도 안 함 |
| `FRESH` | `create_all` | **기동 거부** |
| `ADDITIVE` | `create_all` (없는 테이블만 생성). **데이터 보존** | **기동 거부** |
| `DRIFTED` | 리셋 후 재생성 + WARNING | **기동 거부** |

**서버에서 guard는 스키마를 절대 수정하지 않는다.** 일치하지 않으면 어떤 판정이든
`RuntimeError`로 기동을 거부하고 `alembic upgrade head`를 안내한다.

이유는 소유권이다. 서버 스키마는 Alembic이 소유한다. guard가 서버에서 테이블을 만들어
버리면 Alembic의 head revision과 실제 스키마가 어긋나고, 다음 배포에서 그 테이블을 다시
만들려다 `table already exists`로 실패한다. 두 도구가 같은 스키마를 쓰면 안 된다.

따라서 `ADDITIVE`는 **로컬 전용 편의**다. 팀원이 Phase 2를 pull했을 때 신규 테이블만
만들어 주고 기존 로컬 데이터를 지키는 것이 목적이다. 서버에 신규 테이블을 올릴 때는
migration이 필요하며, 신규 테이블은 autogenerate가 가장 안정적으로 처리하는 경우다.

### 3-4. 리셋 절차 (로컬 `DRIFTED`만)

`Base.metadata.drop_all`을 쓰지 않는다. 그 함수는 **models.py가 아는 테이블만** 지우므로
Phase 1이 제거한 `parent_profiles`가 DB에 남는다. 지운 줄 알았는데 살아있는 상태가 되어
원래 문제가 반복된다.

실제 DB를 reflect해서 거기 있는 전부를 지운다.

```
reflected = MetaData()
await conn.run_sync(reflected.reflect)
await conn.run_sync(reflected.drop_all)
await conn.run_sync(Base.metadata.create_all)
```

reflect가 외래키를 함께 읽으므로 `drop_all`의 삭제 순서가 정렬된다. `calls` →
`audio_assets`/`transcripts`/`acoustic_features`처럼 얽힌 구간이 여기에 걸린다.

### 3-5. 설정

`SCHEMA_AUTO_RESET` (bool, 기본 `true`)를 `Settings`에 추가한다.

**`app_env`로 분기하지 않는다.** `api.py:171,185`에서 `app_env == "production"`은 dev OTP를
랜덤 6자리로 바꾸고 응답의 `devCode`를 숨긴다. SMS 발송 provider가 아직 없으므로
(`HANDOFF.md` 의도적으로 미완료) 배포 서버를 `production`으로 띄우면 아무도 로그인할 수
없다. 따라서 2026-08-18 서버는 `APP_ENV=development`로 뜰 수밖에 없고, 리셋 여부를
`app_env`에 묶으면 공용 서버가 스키마 변경마다 DB를 날린다.

카카오 로그인이 들어와도 유지한다. 계획서 29행이 "개발용 OTP는 유지한다"로 확정했고, DB
리셋 여부와 인증 모드는 독립적으로 바꿀 수 있어야 하는 별개의 축이다.

`docker-compose.yml`의 `backend` 서비스에 `SCHEMA_AUTO_RESET: ${SCHEMA_AUTO_RESET:-true}`를
추가해 로컬 기본값을 유지한다.

### 3-6. 로그

`DRIFTED` 리셋 시 WARNING으로 원인과 복구 방법을 함께 남긴다.

```
스키마가 어긋나 개발 DB를 재생성했습니다.
  변경된 테이블: users, consent_records
  데모 데이터를 다시 채우려면: uv run python scripts/seed_demo_family.py
```

서버에서 거부할 때는 같은 정보와 `alembic upgrade head` 안내를 남긴다. `ADDITIVE`는 INFO로
생성한 테이블 목록만 남긴다.

## 4. Alembic

### 4-1. 범위

**서버 전용이다.** 로컬 일상 개발에서는 돌리지 않는다. `SCHEMA_AUTO_RESET=false`인 환경이
Alembic이 스키마를 소유하는 환경이다.

- `backend/alembic.ini`
- `backend/migrations/env.py` — `target_metadata = Base.metadata`. 모델이 등록되도록
  `app.models`를 import한다. `DATABASE_URL`이 `postgresql+asyncpg://`이므로 alembic의 async
  template(`run_async_migrations` + `connection.run_sync`)을 사용한다
- `backend/migrations/versions/` — baseline 1개

`app/schema_guard.py`는 모델을 정의하지 않으므로 import 대상이 아니다. guard는 저장 테이블
없이 reflect 비교만 한다.

### 4-2. Dockerfile

현재 `Dockerfile`은 `app`과 `scripts`만 COPY한다. 그대로 두면 이미지에 migration이 없어
컨테이너에서 `alembic upgrade head`를 돌릴 수 없다.

```
COPY alembic.ini ./
COPY migrations ./migrations
```

### 4-3. baseline 일정

**2026-08-18 직전에 지우고 다시 뽑는다.** 그때까지 만드는 baseline은 리허설용이다. 서버에
실제로 올라갈 baseline은 그 시점의 최종 모델에서 나와야 히스토리가 깨끗하다.

```bash
rm backend/migrations/versions/*.py
# 이후 4-5의 리허설을 빈 DB에서 처음부터 다시 돌린다
```

### 4-4. 생성 결과 검토

autogenerate는 빠뜨리는 것이 있으므로 생성된 파일을 눈으로 읽는다. 다만 이 모델에서 실제
위험 표면은 좁다.

| 일반적 취약점 | 이 코드베이스 | 확인 필요 |
|---|---|---|
| Postgres native ENUM (`CREATE TYPE` 누락) | `sa.Enum` 컬럼 0개. `StrEnum`은 있으나 컬럼은 `String(n)` | 아니오 |
| `server_default` 누락 | 0개. 전부 Python-side `default=` | 아니오 |
| JSONB | 0개. 순수 `JSON` 8개 | 아니오 |
| 인덱스 | `index=True` 29개, `unique=True` 7개 | **예** |

인덱스만 확인 대상이며, autogenerate가 흔들리는 것은 기존 인덱스와의 diff이지 initial
생성이 아니다. 29개 `create_index`가 모두 나왔는지만 센다.

### 4-5. 리허설

**반드시 compose Postgres에서 한다.** SQLite에서 통과한 migration은 Postgres에서 아무것도
보장하지 않는다.

`docker-compose.yml`의 `postgres`에는 `ports:` 매핑이 없어 호스트에서 직접 접속할 수 없다.
migration은 컨테이너 안에서 돌린다. 서버의 배포 경로와 같고, 4-2의 Dockerfile COPY가
제대로 됐는지도 같은 명령으로 검증된다.

```bash
cd backend
docker compose down -v
docker compose up -d postgres
docker compose run --rm backend alembic upgrade head
SCHEMA_AUTO_RESET=false docker compose up -d backend   # guard가 일치로 통과해야 한다
```

마지막 줄이 리허설의 핵심이다. `alembic upgrade head`가 만든 스키마와 `Base.metadata`가
정확히 같아야 guard가 통과한다. autogenerate가 무언가를 빠뜨렸다면 여기서 `RuntimeError`로
드러난다. **생성된 migration 파일을 눈으로 읽는 것보다 이 검사가 확실하다.**

`revision --autogenerate`도 Postgres에 연결돼야 하므로 같은 방식으로 돌린다. 다만 이쪽은
**파일을 생성**하는데, `backend` 서비스는 `./private`만 마운트하고 소스를 마운트하지 않는다.
그대로 돌리면 생성된 migration이 컨테이너와 함께 버려진다. `migrations/`를 명시적으로
마운트한다.

```bash
docker compose run --rm \
  -v "$PWD/migrations:/app/migrations" \
  backend alembic revision --autogenerate -m "initial"
```

Linux 서버에서 돌리면 생성된 파일이 root 소유가 된다. 호스트에서 편집하려면 `chown`이
필요하다. macOS Docker Desktop에서는 문제되지 않는다.

이것이 2026-08-18 서버의 첫 기동과 정확히 같은 경로다. 매일 할 작업이 아니라, **모델을
크게 바꾼 날에만** 한 번씩 돌려 여전히 통과하는지 본다.

### 4-6. 배포 시 실행

서버가 아직 없어 배포 방식이 정해지지 않았다. 이미지가 migration을 포함하도록 4-2를
적용하고, 배포 절차에 다음 순서를 요구사항으로 남긴다.

```
alembic upgrade head   →   앱 기동
```

앱은 `SCHEMA_AUTO_RESET=false`로 뜨므로, migration을 건너뛰거나 migration이 불완전하면
guard가 기동을 거부한다. 순서를 잊어도 조용히 잘못된 상태로 뜨지 않는다.

## 5. 배포 제약 (가비아 클라우드)

이 절은 제약 기록이다. 배포 자체는 이 spec의 범위가 아니며 서버가 생긴 뒤 별도로 다룬다.
스키마 설계가 전제하는 환경을 고정해 두는 것이 목적이다.

### 5-1. 사양과 기간

| 항목 | 값 |
|---|---|
| CPU | 2 vCore (High CPU) |
| 메모리 | **4 GB** |
| 트래픽 | 1 TB |
| 공인 IP | 1개 |
| 기간 | **2026-08-18(화) ~ 2026-08-28(금), 10일** |

서버가 2026-08-28에 사라진다. 그 안에 데모가 끝나야 하며, 이 기간 내내 실기기 통화 기록이
보존돼야 한다(1-2절).

### 5-2. 메모리: Egress를 켤 수 없다

`docker-compose.yml`의 `egress`는 `shm_size: "1gb"`와 `cap_add: ["SYS_ADMIN"]`을 요구한다.
LiveKit Egress는 내부적으로 Chrome/GStreamer를 실행한다.

| 서비스 | 대략 |
|---|---|
| postgres + redis + minio | ~500 MB |
| livekit | ~200 MB |
| **egress** | **1 GB shm + Chrome/GStreamer 1~1.5 GB** |
| backend (librosa/numpy) | ~400 MB |
| backend + onnxruntime (`feat/hear-cough-detector` 병합 후) | +~200 MB |

4 GB를 넘긴다. 2 vCore에서 Egress 트랜스코딩과 `librosa.pyin`을 동시에 돌리는 것도 무리다.

**따라서 가비아 서버는 `ALLOW_RAW_ONLY_ANALYSIS=true`로 운영한다.** 이 mode는 `/accept`가
Track Egress 조회·시작을 건너뛴다(2026-08-13 `fix/skip-track-egress-raw-only`에서 도입,
회귀 test 있음).

이 구성에는 선행 조건이 있다. 현재 raw-only는 부모 PCM만 다루므로 양 참여자 분석이 되지
않는다. 계획서 Phase 2의 "양쪽 기기의 PCM upload 권한과 `AudioAsset.ownerUserId` 추가"가
완료돼야 Egress 없이도 두 참여자를 분석할 수 있다.

**정리하면 2026-08-18 전에 끝나야 하는 것은 Phase 1만이 아니라 Phase 2의 PCM 양방향
업로드까지다.**

### 5-3. 도메인과 TLS: 미결정

공인 IP만 있고 도메인이 없다. Let's Encrypt는 IP 주소에 인증서를 발급하지 않는다. iOS ATS는
기본적으로 HTTPS를 요구하며 `ios/Collog/Info.plist`에 `NSAppTransportSecurity` 항목이 이미
있으나 LAN 개발용이다.

선택지는 셋이며 **2026-08-18 전에 정해야 한다.**

| 방식 | 장점 | 단점 |
|---|---|---|
| 무료 도메인(duckdns 등) 또는 `nip.io` + Let's Encrypt | 정식 HTTPS, ATS 예외 불필요 | 도메인 발급·인증서 갱신 절차 |
| ATS 예외를 공인 IP로 확대 | 가장 빠름 | App Store 심사 대상이면 불가. Xcode 직접 설치 데모에는 무방 |
| 자체 서명 인증서 | 외부 의존 없음 | iOS 기기마다 신뢰 프로파일 설치 필요 |

이 결정은 코드가 아니라 운영 선택이므로 `HANDOFF.md` 의도적으로 미완료에 조건과 함께
기록한다.

### 5-4. 스키마 설계에 미치는 영향

- 서버는 `SCHEMA_AUTO_RESET=false`, `ALLOW_RAW_ONLY_ANALYSIS=true`, `APP_ENV=development`로
  뜬다. 마지막 값은 3-5절의 이유(dev OTP)로 강제된다.
- 서버 수명이 10일이므로 Alembic이 감당해야 하는 것은 그 기간의 스키마 변경뿐이다.
  baseline 하나와 그 위의 소수 migration으로 충분하며, 긴 revision 히스토리를 설계할 필요가
  없다.

## 6. 동작 예시

**팀원이 Phase 1을 pull**: `DRIFTED`. DB가 재생성되고 WARNING이 뜬다. seed 한 번이면 복구.
기억할 명령이 없다.

**스키마 변경 없이 재시작**: 모델과 DB가 같으므로 아무 일도 없다. 데이터 유지.

**팀원이 Phase 2를 pull (신규 테이블만)**: `ADDITIVE`. 새 테이블만 생기고 **로컬 데이터는
그대로 남는다.** 리셋되지 않는다.

**Phase 2를 서버에 배포**: migration을 만들어 `alembic upgrade head`를 돌린다. 신규 테이블
추가라 autogenerate가 안정적으로 처리하고, **실기기 통화 기록은 그대로 남는다.** migration을
잊고 앱만 올리면 guard가 `ADDITIVE`를 감지해 기동을 거부한다.

**18일 이후 기존 테이블 컬럼 변경**: 같은 절차. guard가 `DRIFTED`로 거부하고, `alembic
upgrade head`가 데이터를 유지한 채 반영한다.

**테스트**: `tests/conftest.py`가 테스트마다 `tmp_path`에 빈 SQLite를 만들므로 항상 `FRESH`
경로다. 기존 테스트의 동작과 소요 시간은 바뀌지 않는다.

## 7. 파일 변경

| 파일 | 변경 |
|---|---|
| `backend/app/schema_guard.py` | 신규. 스키마 비교, 판정, 리셋 |
| `backend/app/database.py` | `create_all()` → `ensure_schema()` |
| `backend/app/main.py` | lifespan 25행 호출부 교체와 결과 로깅 |
| `backend/app/config.py` | `schema_auto_reset` 추가 |
| `backend/docker-compose.yml` | `backend`에 `SCHEMA_AUTO_RESET` 전달 |
| `backend/.env.example` | `SCHEMA_AUTO_RESET=true` |
| `backend/Dockerfile` | `alembic.ini`, `migrations` COPY |
| `backend/pyproject.toml`, `uv.lock` | `alembic` 의존성 |
| `backend/alembic.ini`, `backend/migrations/**` | 신규 |
| `backend/tests/test_schema_guard.py` | 신규 |

`app/models.py`, `app/api.py`, `app/services/*`는 건드리지 않는다.

## 8. 테스트

`tests/test_schema_guard.py`:

1. 빈 DB → `FRESH`, 모든 테이블 생성
2. 변경 없이 재실행 → 판정 없음, 미리 넣어둔 행이 그대로 남음
3. 테이블 하나를 통째로 drop → `ADDITIVE`, 그 테이블만 재생성되고 **다른 테이블 데이터는
   보존됨**
4. 기존 테이블에서 컬럼 하나를 drop → `DRIFTED`, `auto_reset=True`면 전체 재생성
5. `auto_reset=False` + `FRESH` → `RuntimeError`, **테이블이 하나도 만들어지지 않음**
6. `auto_reset=False` + `ADDITIVE` → `RuntimeError`, **DB가 수정되지 않음**
7. `auto_reset=False` + `DRIFTED` → `RuntimeError`, DB는 그대로 유지됨
8. 리셋 시 `Base.metadata`에 없는 스테일 테이블도 사라짐 (reflect 기반 drop 검증)
9. 모델에 없는 여분 컬럼·테이블이 DB에 있어도 판정이 나지 않는다 (오탐 방지)

3번과 4번이 `ADDITIVE`/`DRIFTED` 분리를 검증한다. 하나의 전체 해시로 구현하면 3번이
실패한다.

5번과 6번이 소유권 규칙을 검증한다. 서버에서 guard가 편의로 테이블을 만들면 Alembic head와
어긋나므로, `auto_reset=False`에서는 안전해 보이는 생성조차 수행하지 않아야 한다. 특히 5번은
**2026-08-18에 migration을 돌리지 않고 앱만 올린 경우**다. `빈 DB는 만들어 줘도 안전하다`는
판단으로 `FRESH`를 예외 처리하면 이 test가 `DID NOT RAISE`로 실패한다.

8번은 `Base.metadata.drop_all`로 구현하면 실패한다.

### 8-1. Postgres에서 같은 테스트 돌리기

SQLite는 외래키를 기본적으로 강제하지 않아 reflect 기반 drop의 삭제 순서를 검증하지 못한다.
`GUARD_TEST_DATABASE_URL`을 주면 같은 13개 테스트가 Postgres에서 돈다.

```bash
docker run -d --rm --name collog-guard-pg \
  -e POSTGRES_DB=collog -e POSTGRES_USER=collog -e POSTGRES_PASSWORD=guard-test-only \
  -p 55432:5432 postgres:17-alpine

GUARD_TEST_DATABASE_URL="postgresql+asyncpg://collog:guard-test-only@127.0.0.1:55432/collog" \
  uv run pytest tests/test_schema_guard.py -q

docker stop collog-guard-pg
```

compose가 아니라 독립 컨테이너를 쓴다. 팀원의 `postgres-data` 볼륨을 건드리지 않기 위해서다.
이미지는 compose와 같은 `postgres:17-alpine`이다.

**이 검사에 실제로 힘이 있는지 확인하는 법.** 테이블을 만든 뒤 순진하게 지워 보면 Postgres가
거부한다. 같은 DB에서 `_drop_everything()`이 성공한다면 정렬이 실제로 일을 한 것이다.

```bash
docker exec collog-guard-pg psql -U collog -d collog -c "DROP TABLE users;"
# ERROR: cannot drop table users because other objects depend on it
```

## 9. 완료 조건

```bash
cd backend
uv run ruff check .
uv run pytest -q          # 기존 47개 + 신규 14개
uv build
docker compose config --quiet
```

기능 조건:

- 스키마를 바꾸지 않은 재시작에서 데이터가 보존된다.
- 로컬에서 **신규 테이블 추가만으로는 어떤 데이터도 지워지지 않는다.**
- 기존 테이블이 어긋나면 로컬은 재생성하고 서버는 기동을 거부한다.
- `SCHEMA_AUTO_RESET=false`에서는 DB를 지우지도, 수정하지도 않는다.
- 8-1의 Postgres 실행이 통과하고 결과를 `HANDOFF.md` 6절에 기록한다. SQLite pytest만으로는
  reflect 기반 drop의 외래키 처리를 검증할 수 없다.
- (Alembic 도입 후) 4-5 리허설이 통과한다.

## 10. 함께 갱신할 문서

`HANDOFF.md` 0절 5번이 코드와 문서를 같은 커밋에 넣도록 요구한다.

- `HANDOFF.md` 5절 파일별 역할 표에 `app/schema_guard.py`, `alembic.ini`, `migrations/` 추가
- `HANDOFF.md` 6절에 검증·리허설 결과 기록
- `HANDOFF.md` 7절 동의 append-only 항목에 로컬 DB 리셋 예외 단서 추가
- `HANDOFF.md` 8절 우선순위 1번의 "migration 기반 준비"를 이 설계로 구체화
- `HANDOFF.md` 9절 변경 이력
- `backend/README.md`에 guard 동작, `SCHEMA_AUTO_RESET`, 리허설 절차 추가
- `implementation-plan-v2.md` 98행에 baseline 재생성 시점(2026-08-18 직전)과 guard의 역할 추가

`HANDOFF.md`와 `backend/README.md`는 `feat/hear-cough-detector`도 수정 중이다. 서로 다른
섹션에만 추가하고 기존 항목을 지우지 않으면 auto-merge된다. `pyproject.toml`/`uv.lock`은 그
브랜치가 `onnxruntime`을 추가하고 있으므로, 나중에 머지되는 쪽이 rebase 후 `uv lock`을 다시
생성한다.

## 11. 비목표

- 컬럼 타입 변경 감지. 3-1의 이유로 이름만 비교한다.
- 로컬에서의 Alembic 사용. 리허설과 배포에서만 쓴다.
- 리셋 후 seed 자동 실행. 로그 안내만 한다. seed가 httpx로 자기 서버 API를 호출하는 구조라
  lifespan에서 실행하면 기동 순서 의존과 새 실패 지점이 생긴다.
- 자동 배포 파이프라인. 서버가 생긴 뒤 별도로 다룬다.
