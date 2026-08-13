# 피그마 정합화 구현 계획 v2

마지막 갱신: 2026-08-13

상태: 제품 기본안 확정, 구현 전

이 계획은 2026-08-13 피그마 전체 흐름과 `profile-question-report-design.md`를 기준으로 한다.
사용자는 별도로 결정할 수 없는 항목만 질문하고 나머지는 권장 기본안으로 진행하도록 승인했다.

## 1. 확정 기본안

### 사용자·가족·통화

- 모든 가족 구성원은 건강 프로필과 리포트의 주체가 될 수 있다.
- `부모/자녀`는 전역 사용자 role이 아니라 가족 안의 관계다. 한 사용자가 어떤 가족에서는
  자녀이고 다른 가족에서는 부모일 수 있다.
- 통화는 양방향이다.
- 한 통화에는 건강 분석 대상 `subjectUserId`가 한 명만 존재한다.
- MVP에서는 홈에서 선택한 통화 상대방, 즉 callee를 subject로 자동 지정한다.
- caller와 callee의 음성을 분리하되 STT/LLM/음향 건강 사실은 subject를 기준으로 계산한다.
- subject가 유효하게 분석에 동의하지 않았으면 일반 통화는 허용하고 녹음·전사·음향·리포트만
  끈다.

### 인증·초대·동의

- 사용자용 인증은 카카오 로그인을 목표로 하고 개발용 OTP는 유지한다.
- 카카오·문자·코드 초대는 모두 동일한 초대 token/deep link를 전달하는 채널이다.
- 초대 확인 → 로그인 → 동의 → 가족이 제안한 프로필 확인 순서를 사용한다.
- 초대/동의 전에는 제3자의 건강정보를 서버에 확정 저장하지 않는다.
- 가족 입력은 `FAMILY_PROPOSED`, 당사자 입력은 `SELF`로 기록하며 당사자 확인값이 우선한다.
- 동의는 건강정보 수집, 통화 분석, 음향 특징, 가족 공유 항목을 versioned append-only record로
  남긴다.
- 동의 철회 시 이후 분석을 즉시 중단하고 공유 접근을 차단한다. 원본 오디오는 이미 폐기돼야
  하며, 파생 건강 observation/리포트는 purge job으로 삭제한다. 철회 사실 자체는 감사 기록으로
  유지한다.

### 건강 프로필

- 모든 subject에 대해 진단받은 질환, 복용약, 진단되지 않은 걱정 항목을 분리한다.
- MVP 질환 code는 당뇨, 고혈압, 고지혈증, 천식, 비만, 호흡기질환, 관절질환, 심장질환과 기타다.
- 치매·인지저하는 확정 질환과 `기억력이 걱정됨` 같은 concern을 구분한다.
- 약은 이름, 복용 시간/횟수, 목적, active 여부를 저장한다. 용량은 선택값이다.
- 기타 질환/최근 걱정은 free text를 허용하되 질문/리포트에 그대로 의료 판단으로 사용하지 않는다.
- 가족은 변경을 제안할 수 있고 subject가 확인·수정한다. 변경자, source, version, confirmedAt을
  보존한다.

### 질문·TTS

- 임의의 의료 질문을 Gemini가 자유 생성하지 않는다. 검수된 versioned template에서 선택한다.
- Gemini는 필요할 때 template 순위화와 안전한 표현 변형만 담당한다.
- 한 통화에 비교용 anchor 질문 1개와 프로필/이전 관찰 기반 dynamic 질문 1개를 기본 제공한다.
- 화면에는 두 질문을 모두 보여주고 ElevenLabs는 우선순위 1위 질문만 발신자에게 읽는다.
- TTS는 발신 시작 후 재생하고 상대가 수락하면 즉시 중단한다. 상대방에게는 송출하지 않는다.
- 질문은 `응/아니`보다 standalone 답변을 유도하는 개방형 문장으로 작성한다.
- 이전 통화에서 지속 확인이 필요한 항목은 규칙 기반 후속 질문 후보가 된다.

### STT·LLM·보관

- Deepgram으로 양쪽 track을 전사하고 시간축으로 합쳐 질문 문맥을 복원한다.
- 건강 fact는 subject 발화 또는 검증된 question-answer pair에서만 생성한다.
- 짧은 `응/아니/괜찮아`는 실제로 인접한 질문과 연결되고 두 segment가 모두 근거일 때만
  해석한다.
- MVP 추출 범주는 증상, 복약, 활동, 수면, 식사, 일상 기능이다.
- 기분·자살·응급도를 자동 판정하거나 별도 응급 운영으로 연결하는 기능은 MVP 범위에서 제외한다.
- 전체 transcript는 분석 중에만 사용한다. 성공 후에는 건강 관련 최소 evidence snippet,
  중립적 요약, segment timing만 저장하고 전체 transcript는 purge한다.
- 추출 실패는 숫자나 사실을 채워 넣지 않고 `ANALYSIS_FAILED`로 표시해 제한 재시도한다.

### 음향·기준선

- 기침·발화 속도·휴지·F0·되묻기·응답 지연은 자기보고를 보조하는 관찰값이다.
- 검증되지 않은 detector는 `UNMEASURABLE(DETECTOR_UNVALIDATED)`로 저장하고 UI에서 숨긴다.
- 기침은 검증 후에도 `분석 가능 N분 중 기침 의심 M건`으로만 표현한다.
- 질환명, 위험군, 응급도와 연결하지 않는다.
- 같은 시간대의 유효 통화가 4개 calendar week에 걸쳐 최소 주 1회 쌓이기 전에는 비교 문장을
  만들지 않고 `기준선 수집 중`으로 표시한다.
- 해커톤 시연용 과거 4주 데이터는 명확히 더미로 표시해 seed한다.

### 리포트·공유

- 통화 직후에는 당사자 직접 언급, 데이터 충분성, 검증된 음향 관찰, 다음 확인 항목을 보여준다.
- 주간은 calendar week, 월간은 calendar month로 집계한다.
- 변화 상태는 `NEW`, `PERSISTING`, `IMPROVED`, `UNCERTAIN`, `INSUFFICIENT_DATA`다.
- 규칙 코드가 event와 변화 상태를 결정하고 Gemini는 근거 범위 안에서 문장을 다듬는다.
- 프로필 사실, 통화 자기보고, 음향 관찰, 기간 집계를 API와 UI에서 구분한다.
- 자기 리포트는 본인이 항상 열람할 수 있다. 가족별로 프로필/리포트/타임라인 공유를 허용한다.
- 기본 가족 공유는 요약이며 짧은 원문 evidence는 subject가 허용할 때만 보여준다.

### API·DB·시연

- 기존 `/parents/*` API는 즉시 제거하지 않고 subject 기반 API를 추가한 뒤 deprecated adapter로
  유지해 기존 iOS 작업과의 충돌을 줄인다.
- schema 변경은 Alembic migration으로 남긴다. 테스트는 새 DB, 개발 Compose는 migration을
  사용하며 volume 삭제에 의존하지 않는다.
- 핵심 시연은 카카오/개발 로그인 → 초대 → 동의/프로필 확인 → 맞춤 질문/ElevenLabs → 두
  iPhone 통화 → STT/Gemini → 통화 결과 → 더미 과거 데이터가 포함된 주간 리포트 순서다.
- 더미 데이터와 실제 통화 결과는 UI와 발표에서 구분한다.

## 2. 단계별 구현 계획

### Phase 0 — 안전 차단과 계약 fixture

목표: 잘못된 건강값이 노출되는 상태를 먼저 제거하고 새 계약을 테스트로 고정한다.

- cough `0.0 OK`를 `UNMEASURABLE(DETECTOR_UNVALIDATED)`로 전환
- 현재 API flow와 새 subject flow의 golden fixture 작성
- 새 enum/source/consent/report 상태를 OpenAPI 초안에 반영
- migration 도구와 test migration smoke test 추가

완료 조건:

- 검증되지 않은 cough가 리포트/API의 정상값으로 노출되지 않는다.
- v2 fixture가 사용자 관계, subject, consent 경계를 명시한다.

### Phase 1 — 가족 그래프·건강 주체·프로필

목표: `PARENT` 하드코딩을 제거하고 모든 가족 구성원을 건강 주체로 표현한다.

- 사용자 전역 role 의존을 관계 기반 권한으로 교체
- family membership/invitation을 실제 사용자와 pending invite 모두 표현하도록 정리
- `HealthProfile`, `HealthCondition`, `Medication`, `HealthConcern`, profile revision/source 추가
- `FAMILY_PROPOSED → SELF_CONFIRMED` 흐름과 충돌 규칙 구현
- 동의 전 health write 거절, 본인/공유자 read/write 권한 test
- 동의 철회 purge와 공유 차단 test

예상 영향 파일:

- `app/models.py`, `app/schemas.py`, `app/services/domain.py`, `app/api.py`
- migration, API flow tests, OpenAPI 문서

완료 조건:

- 부모와 자녀 어느 계정도 subject가 될 수 있다.
- 질환·약·걱정과 source/확인 상태가 round-trip 된다.
- 다른 가족이나 미동의 사용자의 데이터에 접근할 수 없다.

### Phase 2 — subject 기반 양방향 통화

목표: caller/callee/subject를 분리하고 기존 LiveKit 파이프라인을 보존한다.

- `CallRecord`에 caller/callee/subject 의미를 명시
- `/calls`에서 관계·차단·subject 동의를 검증
- 양방향 APNs/CallKit 수신과 LiveKit token 발급
- subject track 선택, subject PCM/STT/음향 처리
- 기존 `/parents/*` adapter와 iOS client transition 계약 제공

완료 조건:

- A→B와 B→A 모두 통화되며 각 통화에서 callee만 health subject로 분석된다.
- 동의하지 않은 subject 통화에서는 어떤 분석 asset도 생성되지 않는다.

### Phase 3 — 질문 정책·ElevenLabs

목표: 프로필과 이전 관찰이 실제 질문으로 연결되는 것을 보인다.

- versioned `QuestionTemplate` catalog와 topic/profile mapping
- anchor 1 + dynamic 1 deterministic selector
- 이전 질문 중복 회피, unresolved observation follow-up
- `selectionReason`, `profileItemIds`, `templateVersion`, `anchorGroup` API 필드
- top question만 ElevenLabs asset 생성/cache, 나머지는 화면 text 제공
- 프로필 변경 시 질문 cache invalidation

완료 조건:

- 동일 seed는 동일 질문을 선택하고, 프로필/이전 관찰 변경은 예상한 질문만 바꾼다.
- 수락 즉시 TTS가 중단되고 실패 시 iOS local fallback이 동작한다.

### Phase 4 — Q/A 근거 추출·최소 보관

목표: 통화 내용이 근거 있는 health observation으로 변환되고 전체 전사는 남지 않게 한다.

- `SUBJECT/FAMILY` segment와 question-answer pair builder
- 여섯 extraction category, polarity, questionId, evidence schema v3
- 짧은 응답, 정정, 부정, 질문 유도, prompt injection eval 확장
- success 후 transcript purge/minimal evidence persistence
- 실패 retry/idempotency와 purge 보장

완료 조건:

- 모든 fact가 실제 존재하는 근거 segment 또는 검증된 Q/A pair를 참조한다.
- 다른 화자의 추측과 진단·원인·치료 문장이 저장되지 않는다.
- 처리 후 원본 audio와 전체 transcript가 남지 않는다.

### Phase 5 — 통화 결과·주간·월간 리포트 v2

목표: 문자열 모음이 아닌 health observation의 시간 변화로 리포트를 만든다.

- typed `HealthObservation`과 기간 비교 service
- 통화 직후 result endpoint
- calendar weekly/monthly report snapshot
- NEW/PERSISTING/IMPROVED/UNCERTAIN/INSUFFICIENT_DATA 결정 규칙
- 다음 질문 추천과 근거, 분석 통화 수/분, 제외 count
- 공유 scope와 타임라인 endpoint
- Gemini는 집계된 JSON을 표현하는 renderer로만 사용

완료 조건:

- 리포트의 모든 문장이 observation/call/profile source로 역추적된다.
- 데이터가 부족하면 변화 문장 대신 명시적 부족 상태를 반환한다.
- 본인과 허용된 가족만 같은 snapshot을 열람한다.

### Phase 6 — 음향 모델 검증과 보조 연결

목표: 검증된 지표만 리포트의 별도 관찰 카드에 추가한다.

- speech rate/pause/F0/repair의 실제 iPhone 품질·성공률 측정
- HeAR Small/YAMNet cough bake-off와 in-domain label set 평가
- response latency/prompt-anchored window 후보 검증
- detector/analyzer version, 분모, confidence, unmeasurable reason 보존
- 기준선 collecting/ready 상태와 report 연결

완료 조건:

- 각 노출 지표에 label set 기반 precision/recall 또는 측정 성공률 근거가 있다.
- 검증 실패 지표는 UI/API 정상 관찰값에서 제외된다.

### Phase 7 — iOS 정합화·전체 시연

목표: 피그마 흐름과 backend contract를 실제 두 iPhone에서 연결한다.

- 카카오/개발 로그인, 초대 deep link, 동의, 프로필 확인 화면 연결
- 홈 질문 미리보기, 양방향 발신, 통화 화면, 통화 직후 결과
- 리포트/타임라인/공유 화면 API 연결
- 4주 더미 seed와 오늘의 실제 통화 결합
- 두 iPhone preflight 및 E2E 자동 판정 확장

완료 조건:

- 두 iPhone 양방향 음성, TTS 즉시 중단, subject STT, fact evidence, purge, 통화 결과와 주간
  리포트까지 하나의 시연에서 확인된다.

## 3. 질문하지 않고 사용하는 실행 원칙

- 안전성과 개인정보가 충돌하면 최소 수집·subject 권한을 선택한다.
- 기존 팀원 코드와 충돌하면 삭제/덮어쓰기보다 adapter와 additive migration을 선택한다.
- 불완전한 AI 결과는 placeholder 수치로 채우지 않고 `UNMEASURABLE`/`FAILED`로 표시한다.
- 의료 판단 문구보다 관찰 사실, 분모, 비교 기간, 데이터 충분성을 표시한다.
- 해커톤 범위를 넘는 운영 기능은 interface와 문서만 남기고 핵심 E2E를 우선한다.

## 4. 실제로 질문이 필요한 경우

아래는 코드로 추론할 수 없어 해당 단계에 도달했을 때만 요청한다.

1. 카카오 developer app의 실제 native/REST key, redirect URI와 bundle 연결 권한
2. Apple signing/APNs 자격증명 또는 실기기에서만 가능한 확인
3. 외부 공개 서버의 domain, TLS, 배포 계정 권한
4. 팀원이 동시에 수정 중인 동일 iOS 파일 때문에 안전한 병합이 불가능한 경우
5. 배포 전 법무 검토를 거친 최종 동의 문구와 실제 보존 기간

이 정보가 없어도 mock/local adapter, API, schema, tests, 문서는 계속 구현한다.
