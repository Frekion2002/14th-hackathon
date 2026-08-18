import SwiftUI

// 피그마 `건강 타임라인 화면`(92:5178 / 92:5249).
//
// 피그마는 통화별로 「건강 대화 항목」 한 문장과 「음향 지표 변화」 4종을 보여준다.
// 서버에 통화별 observation 묶음 endpoint는 아직 없으므로(implementation-plan-v2 Phase 5),
// 통화 목록을 세로로 쌓고 각 통화의 실제 추출/음향 결과를 열어보게 한다.
struct HealthTimelineView: View {
    @ObservedObject var model: HomeDashboardModel

    @State private var range: Range = .month3

    enum Range: String, CaseIterable {
        case month1 = "1개월"
        case month3 = "3개월"
        case all = "전체"

        var days: Int? {
            switch self {
            case .month1: return 30
            case .month3: return 90
            case .all: return nil
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                HStack {
                    Text("건강 타임라인")
                        .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)
                    Spacer()
                    Picker("기간 설정", selection: $range) {
                        ForEach(Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Collo.Color.orange)
                }

                if model.subjectId == nil {
                    Text("건강 주체를 먼저 선택해주세요")
                        .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                } else if filteredCalls.isEmpty {
                    Text("이 기간에 기록된 통화가 없어요")
                        .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                }

                ForEach(filteredCalls) { call in
                    NavigationLink {
                        CallResultView(call: call, subjectName: model.subjectName)
                    } label: {
                        entry(call)
                    }
                    .buttonStyle(.plain)
                }

                Text("비교 기간: 최근 4주 동일 시간대 통화 기준")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("타임라인")
        .background(Collo.Color.gray00)
        .refreshable { await model.reload() }
        .task { await model.loadInitial() }
    }

    private var filteredCalls: [CollogAPI.CallSummary] {
        guard let days = range.days else { return model.calls }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            return model.calls
        }
        return model.calls.filter { ($0.startedAtDate ?? .distantPast) >= cutoff }
    }

    private func entry(_ call: CollogAPI.CallSummary) -> some View {
        HStack(alignment: .top, spacing: Collo.Space.s3) {
            VStack(spacing: 0) {
                Circle()
                    .fill(call.isAnalyzed ? Collo.Color.orange : Collo.Color.gray300)
                    .frame(width: 8, height: 8)
                Rectangle().fill(Collo.Color.gray300).frame(width: 1)
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: Collo.Space.s2) {
                Text("\(weekLabel(call)) 통화 (\(model.subjectName))")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                Text(dateLabel(call))
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                Text(stateLabel(call.state))
                    .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
                if let seconds = call.durationSec {
                    Text("통화 \(seconds / 60)분 \(seconds % 60)초")
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Collo.Color.gray600)
        }
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private func weekLabel(_ call: CollogAPI.CallSummary) -> String {
        guard let date = call.startedAtDate else { return "날짜 미상" }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let weekOfMonth = calendar.component(.weekOfMonth, from: date)
        return "\(month)월 \(weekOfMonth)주차"
    }

    private func dateLabel(_ call: CollogAPI.CallSummary) -> String {
        guard let date = call.startedAtDate else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일"
        return formatter.string(from: date)
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "ANALYZED": return "분석 완료 · 결과 보기"
        case "ANALYSIS_EXCLUDED": return "분석 제외"
        case "ANALYSIS_FAILED": return "분석 실패"
        case "ENDED": return "분석 대기"
        default: return state
        }
    }
}
