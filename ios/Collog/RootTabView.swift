import SwiftUI
import UIKit

// 피그마 하단 네비게이션(98:21677)의 5개 탭.
// SwiftUI 기본 TabView는 아이콘 24px·라벨 12px·활성 오렌지를 그대로 못 맞춰서
// 커스텀 바로 만든다.
struct RootTabView: View {
    @StateObject private var dashboard = HomeDashboardModel()
    @State private var tab: Tab = .home

    enum Tab: String, CaseIterable {
        case home = "홈"
        case call = "통화"
        case report = "리포트"
        case timeline = "타임라인"
        case settings = "설정"

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .call: return "phone.fill"
            case .report: return "chart.bar.xaxis"
            case .timeline: return "clock.arrow.circlepath"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .home:
                    NavigationStack { HomeDashboardView(model: dashboard) }
                case .call:
                    NavigationStack { CallPrepView() }
                case .report:
                    NavigationStack { ReportTabView(model: dashboard) }
                case .timeline:
                    NavigationStack { HealthTimelineView(model: dashboard) }
                case .settings:
                    NavigationStack { SettingsView(model: dashboard) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
        .background(Collo.Color.gray00)
    }

    private var bottomBar: some View {
        HStack {
            ForEach(Tab.allCases, id: \.self) { item in
                let isSelected = item == tab
                Button { tab = item } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18))
                            .frame(width: 24, height: 24)
                        Text(item.rawValue)
                            .colloText(
                                Collo.Font.caption01_200,
                                isSelected ? Collo.Color.green : Collo.Color.gray600,
                                size: 12
                            )
                    }
                    .foregroundStyle(isSelected ? Collo.Color.green : Collo.Color.gray600)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, Collo.Space.s2)
        .frame(height: 64)
        .background(Collo.Color.gray00)
        .overlay(alignment: .top) {
            Rectangle().fill(Collo.Color.gray200).frame(height: 1)
        }
    }
}

// MARK: - 리포트 탭 (92:5138)

struct ReportTabView: View {
    @ObservedObject var model: HomeDashboardModel
    @State private var period = "WEEKLY"
    @State private var report: CollogAPI.Report?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Picker("기간", selection: $period) {
                    Text("주간").tag("WEEKLY")
                    Text("월간").tag("MONTHLY")
                }
                .pickerStyle(.segmented)

                if isLoading {
                    ProgressView()
                } else if let report {
                    reportBody(report)
                } else if let errorMessage {
                    Text(errorMessage)
                        .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)
                } else {
                    Text("건강 주체를 먼저 선택해주세요")
                        .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                }
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("리포트")
        .background(Collo.Color.gray100)
        .task(id: period) { await load() }
        .task(id: model.subjectId) { await load() }
    }

    @ViewBuilder
    private func reportBody(_ report: CollogAPI.Report) -> some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("건강 변화 리포트")
                .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)

            // 기간·대상 카드 (92:5843). 무엇과 비교한 수치인지 먼저 밝힌다.
            card {
                VStack(alignment: .leading, spacing: Collo.Space.s2) {
                    Text("\(periodLabel(report)) / \(model.subjectName)")
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray700, size: 12)
                    Text("유사한 통화 시간대의 개인 과거 기록과 비교합니다.")
                        .colloText(Collo.Font.caption02_300, Collo.Color.gray600, size: 10)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dateRangeLabel(report))
                        .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 16)
                    Text("분석된 통화 \(report.analyzedCallCount)건")
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                }
            }

            if report.state == "EMPTY" {
                card { Text(report.emptyMessage ?? "이번 기간에 분석된 통화가 없어요") }
            }
            if report.isBaselineCollecting {
                card {
                    VStack(alignment: .leading, spacing: Collo.Space.s1) {
                        Text("기준선 수집 중")
                            .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                        Text("같은 시간대 통화가 4주에 걸쳐 쌓이면 변화를 비교할 수 있어요")
                            .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)
                    }
                }
            }

            // 음향 지표 해석 (92:5826). 지표마다 이번 기간 측정값과 기준선을 나란히 둔다.
            // 서버가 준 값만 쓰므로 기준선이 아직 없으면 비교 칸을 비운다.
            if !report.acousticTrends.isEmpty {
                Text("음향 지표 해석")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 16)
            }
            ForEach(report.acousticTrends) { trend in
                card {
                    VStack(alignment: .leading, spacing: Collo.Space.s2) {
                        HStack {
                            Text(metricLabel(trend.metric))
                                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                            Spacer()
                            Text("\(trend.points.count)회 측정")
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        }
                        TrendLineChart(
                            points: trend.points,
                            baselineMedian: anchorMedian(for: trend.metric)
                        )
                        .frame(height: 88)
                        .frame(maxWidth: .infinity)
                        // 이번 주 N / 기준선 N (92:5830). 피그마 문구는 「직전 3주 평균」이지만
                        // 서버가 주는 값은 ANCHOR 기준선 중앙값이라 있는 그대로 이름 붙인다.
                        HStack(alignment: .top) {
                            Text("이번 기간 \(measurementText(trend))")
                            Spacer()
                            if let median = anchorMedian(for: trend.metric) {
                                Text("기준선 \(valueText(median, metric: trend.metric))")
                            } else {
                                Text("기준선 수집 중")
                            }
                        }
                        .colloText(Collo.Font.caption02_300, Collo.Color.gray700, size: 10)
                        if let first = trend.points.first, let last = trend.points.last,
                            trend.points.count >= 2
                        {
                            HStack {
                                Text(first.date)
                                Spacer()
                                Text(last.date)
                            }
                            .colloText(Collo.Font.caption02_300, Collo.Color.gray600, size: 10)
                        }
                    }
                }
            }

            // 통화 자기보고 — 당사자가 직접 말한 항목만
            ForEach(["symptom", "medication", "activity", "sleep"], id: \.self) { key in
                let items = report.conversationItems[key] ?? []
                if !items.isEmpty {
                    card {
                        VStack(alignment: .leading, spacing: Collo.Space.s1) {
                            Text(categoryLabel(key))
                                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                            ForEach(items, id: \.self) { item in
                                Text("· \(item)")
                                    .colloText(Collo.Font.body02_300, Collo.Color.gray800, size: 14)
                            }
                            Text("이번 통화에서 언급")
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        }
                    }
                }
            }

            // 권장 사항 (92:5839). 승격 신호나 advisory가 있을 때만 낸다.
            if !report.promotedSignals.isEmpty || report.advisory != nil {
                Text("권장 사항")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 16)
            }

            // 음향 관찰 — 검증된 값만 서버가 내려준다
            ForEach(report.promotedSignals) { signal in
                if let text = signal.summaryText {
                    card {
                        VStack(alignment: .leading, spacing: Collo.Space.s1) {
                            Text("지속된 변화 · \(signal.consecutiveWeeks)주 연속")
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                            Text(text)
                                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                        }
                    }
                }
            }

            if let advisory = report.advisory {
                card { Text(advisory).colloText(Collo.Font.body02_300, Collo.Color.gray800, size: 14) }
            }

            Text(report.disclaimer)
                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Collo.Space.s4)
            .background(
                Collo.Color.gray00,
                in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
            )
    }

    private func categoryLabel(_ key: String) -> String {
        switch key {
        case "symptom": return "증상"
        case "medication": return "복약"
        case "activity": return "활동"
        case "sleep": return "수면"
        default: return key
        }
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

    /// 서버 `AcousticFeature.unit`과 같은 단위를 쓴다(acoustics.py).
    private func unitLabel(_ metric: String) -> String {
        switch metric {
        case "SPEECH_RATE": return "음절/분"
        case "PAUSE_RATIO": return "%"
        case "F0_VARIATION": return "세미톤"
        case "COUGH_EVENTS": return "회"
        default: return ""
        }
    }

    private func valueText(_ value: Double, metric: String) -> String {
        let digits = metric == "COUGH_EVENTS" ? 0 : 1
        return "\(String(format: "%.\(digits)f", value))\(unitLabel(metric))"
    }

    /// 이번 기간 대표값. 통화가 여러 건이면 중앙값을 쓴다. 기준선도 주차별 중앙값으로
    /// 세우므로(signals.weekly_medians) 같은 방식이어야 비교가 성립한다.
    private func measurementText(_ trend: CollogAPI.Report.Trend) -> String {
        let values = trend.points.map(\.value).sorted()
        guard !values.isEmpty else { return "-" }
        let median =
            values.count % 2 == 1
            ? values[values.count / 2]
            : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
        return valueText(median, metric: trend.metric)
    }

    /// 비교 기준이 되는 ANCHOR 기준선. 시간대별로 따로 잡히므로 표본이 가장 많은 것을
    /// 고르고, 아직 READY가 아니면 비교하지 않는다.
    private func anchorMedian(for metric: String) -> Double? {
        model.baselines
            .filter { $0.metric == metric && $0.kind == "ANCHOR" && $0.isReady }
            .max { $0.sampleCount < $1.sampleCount }?
            .median
    }

    private func periodLabel(_ report: CollogAPI.Report) -> String {
        report.period == "MONTHLY" ? "월간" : "주간"
    }

    /// 피그마의 `08.03~ 08.09` 표기. 서버가 주는 `2026-08-03` 형태에서 월·일만 뗀다.
    private func dateRangeLabel(_ report: CollogAPI.Report) -> String {
        func short(_ value: String) -> String {
            let parts = value.split(separator: "-")
            guard parts.count == 3 else { return value }
            return "\(parts[1]).\(parts[2])"
        }
        return "\(short(report.from)) ~ \(short(report.to))"
    }

    private func load() async {
        guard let subjectId = model.subjectId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            report = try await CollogAPI.report(parentId: subjectId, period: period)
        } catch {
            report = nil
            errorMessage = error.localizedDescription
        }
    }
}

// 실기기 디버깅용. APNs 검증에 필요한 토큰을 눈으로 확인한다.
struct TokenRow: View {
    let title: String
    let token: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            if let token {
                Text(token)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Button("복사") { UIPasteboard.general.string = token }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("발급 대기 중").foregroundStyle(.secondary)
            }
        }
    }
}
