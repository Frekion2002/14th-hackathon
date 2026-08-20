import SwiftUI

// 피그마 `건강 신호 분석 결과 화면`(92:5070).
//
// 피그마 목업의 숫자(`무릎 통증, 두통`, `분당 약 210음절`, `기준선 대비 +3%p`)는 예시다.
// 화면은 `/calls/{id}/extraction`, `/acoustic-features`, `/transcript`가 실제로 준 값만
// 그리고, `UNMEASURABLE` 지표는 값을 지어내지 않고 사유를 그대로 보여준다.
struct CallResultView: View {
    let call: CollogAPI.CallSummary
    let subjectName: String

    @State private var extraction: CollogAPI.Extraction?
    @State private var acoustics: CollogAPI.AcousticFeatures?
    @State private var transcript: CollogAPI.Transcript?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Text("이번 통화 분석 결과")
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)

                summaryCard

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    conversationCard
                    acousticCard
                }

                noticeCard

                if let errorMessage {
                    Text(errorMessage).colloText(Collo.Font.body02_300, .red, size: 14)
                }
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("건강 신호 분석 결과")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .task { await load() }
    }

    // MARK: - 건강 신호 요약 (92:5070)

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("건강 신호 요약")
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

            row("통화 일시", callDateText)
            row("통화 시간대", timeSlotText)
            row("비교 기간", "최근 4주 동일 시간대 통화")
            row("분석 상태", stateLabel)

            Text("이 결과는 \(subjectName)의 과거 통화 기록을 기준으로 개인 변화 추이를 보여주는 참고 자료입니다.")
                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private var callDateText: String {
        guard let date = call.startedAtDate else { return "기록 없음" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 a h:mm"
        return formatter.string(from: date)
    }

    private var timeSlotText: String {
        switch call.timeSlot {
        case "MORNING": return "오전"
        case "AFTERNOON": return "오후"
        case "EVENING": return "저녁"
        case "NIGHT": return "밤"
        default: return "기록 없음"
        }
    }

    private var stateLabel: String {
        switch call.state {
        case "ANALYZED": return "분석 완료"
        case "ANALYSIS_EXCLUDED": return "분석 제외"
        case "ANALYSIS_FAILED": return "분석 실패"
        default: return call.state
        }
    }

    // MARK: - 건강 대화 항목 (92:5070)

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("건강 대화 항목")
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

            if let extraction, extraction.parseStatus == "OK" {
                let items: [(String, String?)] = [
                    ("증상 언급", extraction.symptom),
                    ("복약 언급", extraction.medication),
                    ("활동 언급", extraction.activity),
                    ("수면 언급", extraction.sleep),
                ]
                ForEach(items, id: \.0) { label, value in
                    row(label, value ?? "언급 없음")
                }
            } else if extraction?.parseStatus == "FAILED" {
                Text("이번 통화의 대화 항목 추출이 실패했어요. 숫자를 채우지 않습니다.")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)
            } else {
                Text("아직 분석 결과가 없어요")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
            }

            if let transcript {
                row("되묻는 표현", "\(transcript.repeatRequestCount)회")
                if transcript.excluded, let reason = transcript.exclusionReason {
                    Text("분석 제외 사유: \(reason)")
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    // MARK: - 음성 신호 지표 (92:5070)

    private var acousticCard: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("음성 신호 지표")
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

            if let acoustics {
                ForEach(acoustics.features) { feature in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(metricLabel(feature.metric))
                                .colloText(Collo.Font.body02_100, Collo.Color.gray800, size: 14)
                            Spacer()
                            // 측정 실패는 숫자 대신 사유를 쓴다. 0으로 채우지 않는다.
                            Text(
                                feature.isMeasured
                                    ? valueText(feature)
                                    : unmeasurableLabel(feature.unmeasurableReason)
                            )
                            .colloText(
                                Collo.Font.body02_100,
                                feature.isMeasured ? Collo.Color.gray900 : Collo.Color.gray600,
                                size: 14
                            )
                        }
                    }
                }
                if let version = acoustics.analyzerVersion {
                    Text("분석기 \(version) · 음원 \(acoustics.audioSource)")
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                }
            } else {
                Text("음향 분석 결과가 아직 없어요")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private func metricLabel(_ metric: String) -> String {
        switch metric {
        case "SPEECH_RATE": return "발화 속도"
        case "PAUSE_RATIO": return "휴지 비율"
        case "F0_VARIATION": return "목소리 높낮이"
        case "COUGH_EVENTS": return "기침 이벤트"
        default: return metric
        }
    }

    private func valueText(_ feature: CollogAPI.AcousticFeatures.Feature) -> String {
        guard let value = feature.value else { return "-" }
        return String(format: "%.1f %@", value, feature.unit)
    }

    private func unmeasurableLabel(_ reason: String?) -> String {
        switch reason {
        case "DETECTOR_NOT_VALIDATED", "DETECTOR_UNVALIDATED": return "검증 전이라 비공개"
        case "MODEL_UNAVAILABLE": return "모델 없음"
        case "MODEL_CHECKSUM_MISMATCH": return "모델 검증 실패"
        default: return "측정 불가"
        }
    }

    // MARK: - 안내 (92:5070)

    private var noticeCard: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s2) {
            Text("안내")
                .colloText(Collo.Font.body02_100, Collo.Color.gray800, size: 14)
            ForEach(
                [
                    "이 분석 결과는 \(subjectName)의 과거 통화 기록을 기준으로 한 개인 변화 참고값입니다.",
                    "의료 진단이나 위험군 판정 기준으로 사용되지 않습니다.",
                    "원본 통화 오디오는 분석 후 즉시 삭제되며 보관하지 않습니다.",
                ],
                id: \.self
            ) { line in
                Text(line)
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
            Spacer(minLength: Collo.Space.s3)
            Text(value)
                .colloText(Collo.Font.body02_100, Collo.Color.gray900, size: 14)
                .multilineTextAlignment(.trailing)
        }
    }

    private func load() async {
        defer { isLoading = false }
        // 세 endpoint 모두 분석 전에는 404다. 하나가 없어도 나머지는 보여준다.
        do { extraction = try await CollogAPI.extraction(callId: call.callId) } catch {
            errorMessage = error.localizedDescription
        }
        do { acoustics = try await CollogAPI.acousticFeatures(callId: call.callId) } catch {
            errorMessage = error.localizedDescription
        }
        do { transcript = try await CollogAPI.transcript(callId: call.callId) } catch {
            errorMessage = error.localizedDescription
        }
    }
}
