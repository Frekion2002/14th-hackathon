# AI-2 실제 음향 지표 설계

상태: hackathon prototype analyzer 구현 완료, 기침 labeled validation·실기기 보정 필요

## 1. 목표와 금지선

부모의 개인 기준선과 비교할 네 관찰값만 계산한다.

- `SPEECH_RATE`: 발화 속도
- `PAUSE_RATIO`: 발화 내부 휴지 비율
- `F0_VARIATION`: 기본주파수의 robust 변동 폭
- `COUGH_EVENTS`: 기침 후보 event 수

이 값으로 질환, 위험군, 응급도나 원인을 판정하지 않는다. 품질이 부족하면 수치를 만들지 않고
`UNMEASURABLE`과 이유를 저장한다.

## 2. 입력과 실행 위치

```text
iOS 48 kHz mono PCM WAV
  ├─ 품질 검사
  ├─ 16 kHz float32 정규화 ── pYIN / transient candidate detector
  ├─ 부모 Deepgram word·utterance timing ── 속도 / 휴지
  └─ voiced frame pYIN ── F0 variation
```

- F0와 기침은 iOS `DEVICE_RAW`만 사용한다. Opus Egress fallback은 codec/AEC 영향 때문에
  해당 두 지표를 `UNMEASURABLE(SOURCE_NOT_RAW)`로 둔다.
- 발화 속도와 휴지는 부모 Track Egress의 Deepgram timing을 사용할 수 있다.
- 48 kHz 원본은 decode 직후 메모리에서만 다루고 VAD/YAMNet용으로 16 kHz mono float32로
  resample한다.
- 현재 CPU 분석은 event loop를 막지 않도록 worker thread에서 실행한다. durable Redis
  `analysis-worker` container 분리는 production 후속 작업이다.
- 최종 특징값과 model/rule version을 저장한 뒤 원본 PCM을 폐기한다.

## 3. 공통 품질 게이트

아래 중 하나라도 실패하면 관련 지표는 `UNMEASURABLE`이다.

| 검사 | 초기 기준 | 실패 이유 |
|---|---:|---|
| WAV decode / mono PCM | 성공 | `INVALID_AUDIO` |
| sample rate | 16/24/44.1/48 kHz 입력 후 16 kHz 변환 가능 | `UNSUPPORTED_SAMPLE_RATE` |
| 부모 발화 | 20초 이상 | `INSUFFICIENT_PARENT_SPEECH` |
| clipping | `abs(sample) >= 0.999` frame 비율 1% 미만 | `EXCESSIVE_CLIPPING` |
| 유효 음량 | speech RMS가 -45 dBFS 초과 | `SIGNAL_TOO_QUIET` |
| 유효 pYIN frame | 2초 이상 | `INSUFFICIENT_VOICED_AUDIO` |

threshold는 해커톤 fixture로 고정하지 않고 실기기 20~30통의 분포를 본 뒤 versioned config로
확정한다.

## 4. 지표별 정의

### 4-1. 발화 속도 `SPEECH_RATE`

한국어 STT text에서 한글 음절 블록(`[가-힣]`) 수를 세고, 부모 utterance의 실제 발화 구간으로
나눈다.

```text
speech_rate = 60 × hangul_syllable_count / articulation_seconds
unit = syllables_per_minute
```

`articulation_seconds`는 각 utterance에서 300ms 이상인 내부 pause를 제외한 시간이다. 최소
10음절·5초 articulation이 필요하다. STT confidence가 낮은 단어는 분자에서 제외하며, 같은
STT model/version끼리만 기준선을 비교한다.

### 4-2. 휴지 비율 `PAUSE_RATIO`

전체 통화 침묵을 사용하면 자녀 말을 듣는 시간이 pause로 잘못 계산된다. 따라서 부모
Deepgram utterance 안의 연속 word timing만 사용한다.

```text
internal_pause = consecutive word gap in [300ms, 2000ms]
pause_ratio = sum(internal_pause) / sum(utterance first-word → last-word window)
unit = ratio (0..1)
```

2초보다 긴 gap과 utterance 사이 gap은 turn-taking으로 보고 제외한다. word timing이 없거나
유효 utterance가 3개 미만이면 측정하지 않는다.

### 4-3. 기본주파수 변동 `F0_VARIATION`

raw PCM을 16 kHz로 변환하고 `librosa.pyin`으로 F0와 voiced probability를 구한다. 초기 범위는
65~400 Hz이며 voiced probability 0.8 이상 frame만 사용한다.

절대 Hz 표준편차 대신 개인의 평균 pitch에 덜 민감한 semitone robust spread를 사용한다.

```text
semitone_i = 12 × log2(f0_i / median(f0))
f0_variation = 1.4826 × median(abs(semitone_i - median(semitone)))
unit = semitone_mad
```

유효 F0 frame이 2초 미만이거나 octave jump가 과도하면 `UNMEASURABLE(PITCH_UNSTABLE)`이다.

### 4-4. 기침 후보 event `COUGH_EVENTS`

현재 `transient-heuristic-v1`은 16 kHz mono waveform을 0.96초 patch/0.48초 hop으로 나눠
상대 에너지 상승, 1 kHz 이상 power 비율, zero-crossing rate, crest factor를 조합한다. threshold
이상 인접 patch를 750ms 기준으로 병합한다. 이는 파이프라인과 개인 기준선 데모를 위한 후보
detector이며 cough로 임상 검증된 classifier가 아니다.

현재 threshold 0.65는 deterministic transient fixture용 초기값이다. 실제 cough 30개와 hard
negative 30개에서 precision 0.85를 만족하기 전에는 production threshold로 간주하지 않는다.
그 평가가 완료되면 YAMNet/별도 cough classifier로 교체하고 detector version을 올린다.

YAMNet은 범용 AudioSet classifier이지 의료기기용 기침 진단 model이 아니다. 따라서 UI에는
항상 “기침 후보 event” 또는 검수 후 “기침 event”로만 표시한다.

## 5. 기준선과 robust Z

- 동일인·동일 time slot의 과거 값만 사용한다.
- 현재 통화는 기준선 계산에서 제외한다.
- calendar week별 median 한 개로 집계하고 최소 4개 서로 다른 주가 필요하다.
- `robust_z = 0.6745 × (current - median) / MAD`를 사용한다.
- MAD가 0이면 epsilon으로 큰 값을 만들지 않고 `UNSCORABLE_ZERO_VARIANCE`로 둔다.
- 방향은 speech rate 감소, pause/cough 증가를 별도로 기록한다. F0 variation은 증가·감소를
  관찰값으로만 보여주고 위험 방향을 단정하지 않는다.
- `4주 연속`은 네 개의 서로 다른 ISO calendar week가 모두 같은 방향이고 중간 결측 주가
  없을 때만 성립한다.

## 6. 현재 실행 계약과 후속 worker

```text
AcousticJob(callId, rawAudioUri, transcriptId, analyzerVersion)
  → measurements[
      metric, value, unit, status, reason,
      source, modelVersion, quality
    ]
```

현재 dependency:

- decode: Python PCM WAV loader, resample: `librosa` + `soxr`
- F0: `librosa.pyin`
- cough: `transient-heuristic-v1`; validation 실패 시 YAMNet/검증된 ONNX classifier로 교체

model artifact는 checksum과 license를 기록하고 container image에 pin한다. 외부 inference API로
raw 건강 음성을 추가 전송하지 않는다.

## 7. 검증 계획과 합격 기준

### deterministic fixture

- 120/180/240 syllables-per-minute 합성 음성
- 0.3/0.6/1.2초 내부 pause를 넣은 음성
- 100/150/220 Hz tone과 알려진 vibrato 폭
- silence, clipping, 저음량, 깨진 WAV

합격 오차:

- speech rate ±5%
- pause ratio 절대오차 ±0.03
- F0 median ±3 Hz, variation ±0.2 semitone
- 품질 실패 fixture는 숫자 대신 정확한 `UNMEASURABLE` reason

### cough validation

실제 건강정보가 아닌 동의된 더미/공개 license 음원으로 cough 30개 이상, hard negative
30개 이상(재채기·목 가다듬기·웃음·문 닫힘)을 label한다. threshold는 precision 우선으로
선택하고 최소 목표를 precision 0.85, recall은 측정값과 함께 공개한다. 이 기준을 못 넘으면
데모에서도 숫자를 확정값으로 표시하지 않는다.

### 실기기 검증

같은 화자가 같은 문장을 다음 조건으로 녹음한다.

- iPhone 기종 2개 이상
- 스피커/수화기, 조용한 방/생활 소음
- Wi-Fi/셀룰러 전환
- 오전/저녁

raw PCM과 Egress 결과를 비교해 source 차이를 기록하되 raw PCM만 개인 기준선의 음향값으로
채택한다.

## 8. 구현 상태와 다음 순서

1. 완료: Deepgram word timing 보존과 Transcript JSON 확장
2. 완료: 16-bit PCM WAV loader, 품질 gate, 16 kHz 변환
3. 완료: word timing speech rate/pause ratio
4. 완료: pYIN F0 variation
5. 완료: versioned transient cough 후보 detector와 deterministic fixture
6. 완료: calendar-week median, MAD=0 `UNSCORABLE`, 결측 주 연속 판정 수정
7. 남음: cough 30/hard-negative 30 validation과 iPhone fixture threshold freeze
8. production 후속: 별도 Redis worker/queue와 model artifact checksum

## 참고

- [Silero VAD](https://github.com/snakers4/silero-vad): 8/16 kHz, speech timestamp와 ONNX 지원
- [librosa pYIN](https://librosa.org/doc/main/generated/librosa.pyin.html): F0, voiced flag,
  voiced probability 제공
- [TensorFlow YAMNet tutorial](https://www.tensorflow.org/hub/tutorials/yamnet): 16 kHz mono 입력과
  AudioSet 521 class score
- [Google AudioSet](https://research.google.com/audioset/): 범용 audio event ontology/dataset
- [Deepgram Utterances](https://developers.deepgram.com/docs/utterances): utterance/word timing
