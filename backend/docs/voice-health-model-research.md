# 음성 건강 신호 모델 조사와 AI-2 의사결정

조사일: 2026-08-13

## 1. 결론

콜록의 방향인 `일상 통화 → 비진단적 관찰값 → 개인 기준선 변화`는 타당하다. 다만 현재
`COUGH_EVENTS`의 handcrafted transient heuristic과 `되묻기 증가 = 난청 확인`이라는 해석은
그대로 유지하면 안 된다.

- 기침 **발생 여부와 횟수**만 필요하면 `google/hear-pytorch` 전체 모델이 아니라 Google이
  별도로 공개한 **HeAR health event detector**가 맞는 1차 후보이다.
- detector도 2초 clip별 확률만 반환한다. 임계값 보정, 겹친 창 병합, event 정의, 음질 gate,
  실제 iPhone 통화 검증이 추가되어야 `COUGH_EVENTS`가 된다.
- `google/hear-pytorch`는 기침 판정기가 아니라 2초 음원을 512차원 표현으로 바꾸는 약 1.21GB
  ViT-L encoder다. 질환·기침 여부를 직접 반환하지 않으며 on-device에는 너무 크다.
- 되묻기는 비의미 음향 모델의 문제가 아니다. STT 문맥에서 대화 수리(conversation repair)를
  찾고 네트워크·음량·내용 확인을 구분해야 한다. 결과명도 `난청 탐지`가 아니라
  `되묻기/청취 어려움 표현 관찰`이어야 한다.
- 발화 속도, 휴지, F0 변동은 실제 서비스에서도 쓰는 탐색적 vocal biomarker지만 원인이나
  질환을 단독 판정하지 못한다. 동일 질문·시간대·기기와 개인 기준선 비교가 핵심이다.
- 공개 음원 30개/negative 30개는 smoke test에는 쓸 수 있지만 성능 검증 표본으로는 부족하다.

해커톤 권고안은 다음과 같다.

1. 현 heuristic은 즉시 `UNMEASURABLE`로 숨기거나 HeAR detector가 준비될 때까지 노출하지 않는다.
2. `HeAR event_detector_small`을 주 후보, `YAMNet`을 공개 baseline으로 같은 라벨셋에서 비교한다.
3. full `hear-pytorch`는 이번 cough-count 경로에서 제외한다.
4. 모델 이름이 아니라 실통화 event precision/recall과 false positives/hour로 최종 선택한다.

## 2. HeAR 그림과 공개 모델의 정확한 관계

첨부된 HeAR 그림은 세 단계를 한 시스템으로 보여준다.

```text
대규모 음원
  → health event detector로 건강 관련 2초 clip 선별
  → 선별 clip으로 HeAR masked-autoencoder 사전학습
  → HeAR embedding 위에 과제별 classifier/regressor 학습
```

이 세 모델은 같은 것이 아니다.

### 2-1. `google/hear-pytorch`

- TensorFlow HeAR의 동등한 PyTorch 구현이다.
- 입력: 16 kHz mono 2초, 즉 32,000 samples.
- 출력: clip마다 512차원 embedding.
- 구조: ViT-L 기반 masked autoencoder의 encoder.
- 공개 weight 파일은 약 1.21GB이며 공식 model card도 on-device에 너무 크다고 명시한다.
- 모델 자체는 기침 여부, 질환, 진단을 출력하지 않는다.
- 사용하려면 downstream label과 별도의 classifier/regressor가 필요하다.

Hugging Face UI의 `image-feature-extraction` 표시는 waveform을 그대로 이미지로 취급한다는 뜻이
아니다. 공식 quick start처럼 waveform을 spectrogram으로 전처리한 뒤 Transformer encoder에
넣어 embedding을 얻는다.

### 2-2. 공개 HeAR health event detector

Google의 공식 `hear_event_detector_demo.ipynb`가 사용하는 detector는 TensorFlow HeAR
repository의 별도 artifact다.

| 항목 | 공개 detector |
|---|---|
| 입력 | 16 kHz mono 2초 waveform |
| frontend | PCEN Mel spectrogram, 200 time steps × 48 bins |
| backbone | MobileNetV3 Small 또는 Large |
| 출력 | 8개 label의 독립 확률 |
| label | Cough, Snore, Baby Cough, Breathe, Sneeze, Throat Clear, Laugh, Speech |
| 규모 | Small 약 1M params/3.60MB, Large 약 3M params/11.46MB |
| 배포 | TensorFlow SavedModel, 공식 notebook에서 LiteRT/TFLite 변환 예제 제공 |

공식 demo의 Wikimedia Commons 음원과 `0.9` threshold는 **사용법 예시**이지 콜록 환경에서
검증된 임계값이 아니다. 그 값을 제품 설정으로 복사하면 안 된다.

### 2-3. 논문 속 detector와 현재 공개 detector의 차이

2024 HeAR 논문 Appendix A의 데이터 선별 detector는 FSD50K, FluSense와 proprietary health
audio로 학습한 작은 CNN으로 설명된다. 2025 공개 notebook의 artifact는 MobileNetV3 기반이며
Snore와 Sneeze까지 포함한 8개 출력을 제공한다. 즉 공개 구현이 논문의 전체 ViT encoder인 것이
아니며, 논문 당시 data-curation detector가 이후 사용 가능한 별도 경량 모델로 공개된 것이다.

HeAR 논문의 성능 표도 구분해서 읽어야 한다. FSD50K cough AP 0.621, FluSense cough AP 0.974,
전체 health-event mAP 0.658은 **HeAR embedding 위에 새 linear probe를 학습한 결과**다. 공개
MobileNetV3 detector의 콜록 실통화 성능을 의미하지 않는다. 논문 저자도 FluSense 일부가
pretraining 자료와 겹쳐 성능이 부풀 수 있고 FSD50K timestamp가 없어 2초 loudness crop을
사용했다는 한계를 적었다.

## 3. “detector만 필요하다”는 말의 판정

모델 계층에서는 맞지만 시스템 계층에서는 불완전하다.

콜록의 목표가 `기침 존재/횟수`라면 foundation embedding과 질환 classifier는 필요 없다.
하지만 detector score만으로 event count는 만들어지지 않는다.

```text
부모 local PCM
  → decode/resample/음질 gate
  → 2초 sliding window
  → cough probability
  → validation split에서 threshold 결정
  → 인접 positive window merge / hysteresis
  → cough-bout timestamp와 peak score
  → 분석 가능 시간으로 정규화
  → 주간 개인 기준선 비교
```

저장할 최소 필드는 다음과 같다.

- `eventStartMs`, `eventEndMs`, `peakProbability`
- `detectorName`, `detectorVersion`, model checksum
- `thresholdVersion`, input source, sample rate
- `analyzableSeconds`, quality failure reason
- raw `eventCount`와 `eventsPerAnalyzableHour`

`event`의 의미도 먼저 고정해야 한다. 하나의 cough bout에는 여러 explosive phase가 있을 수
있으므로 콜록 UI에는 `기침 의심 구간` 또는 `cough bout`를 권장한다. 2초 창의 positive 개수를
그대로 세면 동일한 기침이 중복 집계된다.

부모 local mic도 주변 사람의 기침과 스피커로 재생된 자녀 기침을 받을 수 있다. 따라서
`부모의 기침`이 아니라 우선 `부모 기기 주변의 기침 의심 이벤트`로 정의하고, 실험 negative에
자녀 원격 기침·TV 기침·목 가다듬기·웃음·재채기·파열음·문 닫힘을 넣는다.

## 4. 후보 모델 비교

| 후보 | 장점 | 한계 | 콜록 판정 |
|---|---|---|---|
| 현재 transient heuristic | dependency가 작고 설명 가능 | 실제 통화와 합성 폭발음에서 recall 사실상 0, 현 threshold 도달 불가 | 폐기 baseline |
| HeAR event detector Small | health sound 특화, cough/헛기침/웃음/말 동시 score, 경량, TFLite 가능 | gated license, 일부 proprietary 학습자료, 콜록 domain 성능 미공개 | 1순위 후보 |
| YAMNet | 공개·재현 쉬움, TFLite, 521 AudioSet class, 0.96초/0.48초 frame | 범용 YouTube audio, cough 특화 아님, 전체 mAP 0.306이며 cough별 성능과 다름 | 비교 baseline |
| PANNs | 범용 AudioSet에서 높은 mAP, framewise SED variant | 훨씬 무겁고 모바일/해커톤 운영 복잡 | server reference만 |
| `hear-pytorch` + 새 head | health embedding, 적은 label로 새 task 탐색 가능 | 약 1.21GB, head용 label 필요, cough count에는 과도 | 이번 경로 제외 |

모델 선택 순서는 `HeAR라서 채택`이 아니라 아래 동일 test set의 결과로 결정한다.

1. event precision/PPV
2. event recall/sensitivity
3. false positives per analyzed hour
4. event F1
5. 통화별 count MAE와 수동 count 상관/일치도
6. 기기·소음·화자별 성능 분해
7. 처리시간, 메모리, artifact/license 운영 비용

## 5. 되묻기와 난청

되묻기 증가는 청취 곤란과 관련된 유용한 행동 신호일 수 있지만 난청의 대리 진단값은 아니다.
통화 품질, 스피커 음량, 블루투스 경로, 주변 소음, 발음, 주의력, 기억·언어 이해, 단순한 내용
확인도 같은 표현을 만든다.

실제 청력 screening 서비스는 수동 대화의 되묻기 횟수보다 통제된 active test를 쓴다. WHO의
hearWHO는 23개의 숫자 세 쌍을 배경 소음과 함께 들려주고 speech-to-noise ratio와 0~100 점수를
계산한다. WHO가 인용한 digits-in-noise 방식의 sensitivity와 specificity는 각각 85% 이상이며,
그조차 정식 청력검사를 대체하지 않는 screening이다.

콜록의 권장 구조는 rule 단독이 아니라 `대화 수리 event` 탐지다.

1. 부모 발화를 high-precision rule로 후보화한다.
2. 직전 자녀 발화와 다음 자녀 발화를 함께 묶은 3-turn window를 만든다.
3. 다음 자녀 발화가 실제 반복/바꾸어 말하기인지 확인한다.
4. `HEARING_OR_VOLUME`, `NETWORK_AUDIO`, `CONTENT_CLARIFICATION`, `GENERIC_REPEAT`로 분리한다.
5. LiveKit packet loss/jitter, audio route, remote level이 나쁜 구간은 건강 관찰에서 제외한다.
6. 규칙이 모호할 때만 post-call LLM structured classifier를 사용한다.
7. 분당 횟수 외에 `자녀 정보 발화 100회당 repair initiation`을 함께 계산한다.

LLM latency는 통화 후 분석이므로 핵심 병목이 아니다. 대신 prompt에는 enum, 3-turn evidence,
직접 인용 가능한 transcript span, `UNKNOWN`, 진단 금지를 강제하고 한국어 라벨 fixture로
precision/recall/F1을 측정해야 한다.

UI 문구는 `난청이 의심됩니다`가 아니라 다음 정도가 안전하다.

> 최근 통화에서 다시 말해 달라는 표현이 평소보다 늘었어요. 통화 환경이나 청취 상태의 영향을
> 받을 수 있으니 다음 통화에서 소리 크기와 주변 소음을 먼저 확인해 보세요.

반복적으로 증가하면 정식 청력검사 또는 검증된 한국어 청력 screening 안내로 연결할 수 있다.

## 6. 현재 네 음향 지표 평가

| 지표 | 평가 | 필요한 수정 |
|---|---|---|
| `SPEECH_RATE` | 유지 | 같은 질문/시간대, 같은 STT version, 충분한 articulation time에서 개인 비교 |
| `PAUSE_RATIO` | 정의 수정 전 노출 보류 | Deepgram segment 경계를 넘는 pause 또는 raw PCM VAD 기반으로 turn-taking과 내부 pause 분리 |
| `F0_VARIATION` | 탐색 지표로 유지 | voiced threshold/최소 길이 보정, semitone robust spread, 기기·음질 gate, 원인 해석 금지 |
| `COUGH_EVENTS` | heuristic 교체 | HeAR Small/YAMNet bake-off, temporal merge, FP/hour와 event recall 검증 |

Sonde와 Winterlight 같은 서비스도 speech rate, pause, pitch/energy 변동을 사용하지만 단일 값에
질환명을 붙이지 않는다. Sonde의 공개 문서도 개별 feature range를 임상 reference와 직접
연결하지 않았다고 명시하며, 30초 한 번보다 2주간 반복 측정에서 정신건강 symptom risk
stratification이 개선됐다. 이는 콜록의 개인 내 종단 관찰 방향을 지지하지만 특정 질환 추론을
정당화하지는 않는다.

## 7. 유사 서비스의 모델·서비스 형태·메트릭

서로 다른 task와 cohort의 숫자이므로 아래 성능을 직접 순위 비교하면 안 된다.

| 서비스 | 수집/서비스 형태 | 공개된 모델 형태 | 사용자 출력 | 공개 검증 메트릭 |
|---|---|---|---|---|
| Hyfe CoughMonitor | 스마트워치/폰의 연속 passive monitoring | explosive onset gate → 0.5초 time-frequency image → CNN, 최신 장치는 on-device | timestamp, cough seconds, cough/hour, dashboard | 23명·546시간·4,454 cough: sensitivity 90.4%, PPV 87.5%, FP 1.03/hour, hourly count r=0.99 |
| Google Nest Hub Sleep Sensing | 야간 ambient sensing | on-device cough/snore CNN + radar/mic sensor fusion으로 source 분리 | cough occurrences, snore minutes, sleep timeline | cough detector 수치는 공개 글에 미제시; 의료 목적 아님 |
| ResAppDx | 조용한 환경에서 자발/자연 cough 5회 + 증상 | MFCC/수학 signature → 질환별 SoftMax network와 후처리 | 소아 호흡기 질환별 decision support | 호주 585명: pneumonia PPA/NPA 87%/85%, asthma/RAD 97%/91% 등 |
| Swaasa | 스마트폰 10초, 2~3회 유도 cough + 증상/인구정보 | cough gate, Mel spectrogram ResNet-34 + 170-feature/symptom FFANN, merged head | PTB likely/unlikely/inconclusive | 임상 validation 220명: AUC 0.94, sensitivity 90.36%, specificity 84.67% |
| Sonde Mental Fitness | 30초 open-ended voice journaling 또는 passive SDK | openSMILE/Praat 계열 8 acoustic feature의 proprietary aggregate | 0~100 score와 pitch/energy/speech-rate/pause component | 정신과 외래 104명: elevated symptom risk ratio 1회 1.53, 2주 집계 2.00 |
| Winterlight | 1~5분 picture description/인지 과제 | 550개 이상 acoustic+linguistic feature와 task별 ML | 인지/언어 composite와 임상척도 추정 | 공개 연구: AD 분류 82% accuracy, MMSE MAE 3.8 |
| WHO hearWHO | 헤드폰 active digits-in-noise | 적응형 SNR 기반 hearing screen | 0~100, speech recognition threshold | WHO: sensitivity와 specificity 각각 85% 이상; 정식 검사 아님 |

공통 패턴은 세 가지다.

- **발생량 측정** 서비스는 질환명을 말하지 않고 event timestamp/count/rate를 제공한다.
- **질환 screening** 서비스는 유도 과제, 정답 label, 임상 reference test, cohort validation을
  갖춘 별도 SaMD 성격이다.
- **자연 발화 biomarker** 서비스도 여러 feature를 장기간 집계하며 wellness/monitoring과
  diagnosis를 구분한다.

콜록은 현재 첫 번째와 세 번째 사이에 있어야 하며, 두 번째를 주장하면 안 된다.

## 8. 콜록용 검증 데이터와 합격 기준

### 단계 A: pipeline smoke

- Wikimedia public-domain cough/재채기/웃음/헛기침 샘플
- 기존 30 cough + 30 hard negative
- 목적: 입력/출력, window merge, artifact packaging 확인
- 이 단계의 점수로 제품 성능을 주장하지 않는다.

### 단계 B: 해커톤용 in-domain bake-off

- 최소 5명 이상, 가능하면 10명 이상에서 100개 이상의 동의된 cough bout
- 최소 1시간 이상의 통화 hard-negative 구간
- iPhone 2종, 수화기/스피커, 조용한 방/생활소음
- hard negative: speech plosive, throat clear, laugh, sneeze, tap, door, rustle, TV/상대방 cough
- 동일 사람의 window가 train/calibration/test에 섞이지 않도록 speaker 단위 분리
- 두 명이 onset/offset을 독립 label하고 불일치를 합의
- threshold는 calibration split에서만 정하고 test split은 한 번만 평가

해커톤 공개 최소 기준은 `precision >= 0.85`와 함께 recall 및 FP/hour를 숨김없이 표시하는 것이다.
30/30에서 이 값을 넘겨도 `검증 완료`가 아니라 `데모 gate 통과`로 표현한다.

### 단계 C: 제품/의료 주장

실제 타깃 연령, 기기, 환경의 외부 cohort와 임상 reference가 필요하다. 해커톤 범위 밖이며 이
단계 전에는 특정 질환, 위험군, 치료·진료 필요성을 모델이 출력하지 않는다.

## 9. 구현 우선순위

1. 현재 `0.0 OK` cough 결과를 `UNMEASURABLE(DETECTOR_UNVALIDATED)`로 바꾼다.
2. model terms를 팀 책임자가 수락하고 artifact를 public Git에 바로 commit하지 않는다.
3. HeAR Small SavedModel을 TFLite로 고정하고 checksum/version을 기록한다.
4. 동일 inference interface에 YAMNet adapter를 붙인다.
5. `evals/cough_cases.json`과 event timestamp 기반 calibration CLI를 만든다.
6. threshold/merge gap을 calibration split에서 선택하고 test score를 JSON artifact로 남긴다.
7. 선택 모델을 pipeline에 연결하고 raw PCM purge 불변조건을 회귀 test한다.
8. repeat 3-turn classifier와 LiveKit QoS exclusion을 별도 AI-1 작업으로 진행한다.
9. pause를 raw PCM VAD/turn 기준으로 재정의한 뒤 analyzer version을 올린다.

## 10. 주요 근거

- [Google HeAR PyTorch model card](https://huggingface.co/google/hear-pytorch)
- [Google HeAR 공식 model card](https://developers.google.com/health-ai-developer-foundations/hear/model-card)
- [Google HeAR event detector 공식 notebook](https://github.com/Google-Health/hear/blob/master/notebooks/hear_event_detector_demo.ipynb)
- [HeAR 논문](https://arxiv.org/abs/2403.02522)
- [HAI-DEF 이용약관](https://developers.google.com/health-ai-developer-foundations/terms)
- [Google YAMNet 공식 README](https://github.com/tensorflow/models/blob/master/research/audioset/yamnet/README.md)
- [Hyfe CoughMonitor 임상 검증](https://pmc.ncbi.nlm.nih.gov/articles/PMC11704278/)
- [Google Nest Hub Sleep Sensing](https://research.google/blog/enhanced-sleep-sensing-in-nest-hub/)
- [ResAppDx 소아 호흡기 연구](https://pmc.ncbi.nlm.nih.gov/articles/PMC6551890/)
- [Swaasa PTB 임상 검증](https://www.nature.com/articles/s41598-023-31772-9)
- [Sonde Mental Fitness 연구](https://pubmed.ncbi.nlm.nih.gov/38505797/)
- [Sonde 공개 feature API 설명](https://sondehealth.atlassian.net/wiki/spaces/SA/pages/2706309124/Mental)
- [Winterlight 임상 연구](https://winterlightlabs.com/clinical-research/)
- [WHO hearWHO](https://www.who.int/news-room/questions-and-answers/item/deafness-and-hearing-loss-hearing-checks-and-the-hearwho-app)
