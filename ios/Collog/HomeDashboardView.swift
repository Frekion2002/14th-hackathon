import SwiftUI

// 피그마 `홈 대시보드 화면`(98:21586) 구현.
//
// 표시 문구는 서버가 준 관찰값에서만 만든다. 리포트가 `READY`가 아니면 변화 문장을
// 지어내지 않고 기준선 수집 중 상태를 그대로 보여준다.
// (backend/docs/implementation-plan-v2.md「음향·기준선」)
struct HomeDashboardView: View {
    @ObservedObject var model: HomeDashboardModel
    @ObservedObject private var session = AppSession.shared
    @ObservedObject private var callCenter = VoipCallCenter.shared

    @State private var selectedTab: BodyTab = .callLog

    enum BodyTab: String, CaseIterable {
        case questions = "질문 미리보기"
        case callLog = "전화 로그"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                body_
            }
        }
        .background(Collo.Color.gray00)
        .scrollIndicators(.hidden)
        .refreshable { await model.reload() }
        .task { await model.loadInitial() }
        .safeAreaInset(edge: .top, spacing: 0) { topNavigationBar }
    }

    // MARK: - Top Navigator Bar (145:5405)

    // 초록 변형의 상단 바는 흰 배경이고 아바타 테두리만 초록이다. 아이콘은 회색이라야
    // 흰 배경에서 보인다.
    private var topNavigationBar: some View {
        HStack(spacing: Collo.Space.s3) {
            // Avatar (I145:5405;0:7331)
            Image(systemName: "person.fill")
                .font(.system(size: 20))
                .foregroundStyle(Collo.Color.avatarStroke)
                .frame(width: 42, height: 42)
                .background(Collo.Color.avatarFill, in: RoundedRectangle(cornerRadius: 32))
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(Collo.Color.avatarStroke, lineWidth: 1)
                )

            Spacer(minLength: 0)

            Image(systemName: "bell")
                .font(.system(size: 20))
                .foregroundStyle(Collo.Color.gray900)
                .frame(width: 40, height: 40)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Collo.Color.gray900)
                .frame(width: 40, height: 40)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(Collo.Color.gray00)
    }

    // MARK: - Hero (98:21590)

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            Collo.Color.green

            // 캐릭터: 피그마의 266x175 창에 186% 확대본을 얹고 잘라내는 값을 그대로 옮겼다.
            Image("HomeCharacter")
                .resizable()
                .frame(width: 495.2, height: 330.4)
                .offset(x: -120.6, y: -87.6)
                .frame(width: 266, height: 175, alignment: .topLeading)
                .clipped()
                .offset(x: 115, y: 158.62)

            VStack(alignment: .leading, spacing: 0) {
                Text("\(session.user?.name ?? "회원")님,")
                    .colloText(Collo.Font.body01_200, Collo.Color.gray00, size: 16)
                Text(heroHeadline)
                    .colloText(Collo.Font.headline02_100, Collo.Color.gray00, size: 24)
                if let days = model.daysSinceLastCall {
                    Text("+\(days)일차")
                        .colloText(Collo.Font.headline02_100, Collo.Color.gray00, size: 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
        .frame(height: 276)
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: Collo.Radius.medium,
                bottomTrailingRadius: Collo.Radius.medium
            )
        )
    }

    // 통화 기록이 없으면 경과일을 만들지 않고 첫 통화를 안내한다.
    private var heroHeadline: String {
        model.daysSinceLastCall == nil ? "첫 통화를 시작해보세요" : "전화 주기가 도래했어요"
    }

    // MARK: - Body (98:21604)

    private var body_: some View {
        VStack(spacing: Collo.Space.s4) {
            familyHealthCard
            bodyTabBar
            Group {
                switch selectedTab {
                case .questions: questionList
                case .callLog: callLogList
                }
            }
            if let message = model.errorMessage {
                Text(message)
                    .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Collo.Space.screen)
    }

    // MARK: - 우리 가족 건강 카드 (98:21605)

    private var familyHealthCard: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s4) {
            HStack(spacing: Collo.Space.s1) {
                // MulticolorIcon 「나의 건강」(92:990). SF Symbol에 같은 글리프가 없어
                // 피그마 export를 그대로 벡터 에셋으로 넣었다.
                Image("IconMyHealth")
                    .resizable()
                    .frame(width: 24, height: 24)
                Text("우리 가족 건강")
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)
            }

            VStack(alignment: .leading, spacing: Collo.Space.s2) {
                // Badge (98:21611) — 현재 보고 있는 건강 주체
                Text(model.subjectName.isEmpty ? "대상 없음" : model.subjectName)
                    .colloText(Collo.Font.caption01_100, Collo.Color.blue600, size: 12)
                    .padding(.horizontal, Collo.Space.s2)
                    .frame(height: 26)
                    .background(
                        Collo.Color.blue100,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium)
                    )

                Text(summary.caption)
                    .colloText(Collo.Font.body02_200, Collo.Color.gray800, size: 14)
                Text(summary.headline)
                    .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

                if let detail = summary.detail {
                    Text(detail)
                        .colloText(Collo.Font.body02_100, Collo.Color.gray600, size: 14)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Collo.Space.s1) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(Collo.Color.gray600)
                    Text(analyzedCountText)
                        .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                }

                TrendLineChart(
                    points: model.primaryTrend?.points ?? [],
                    baselineMedian: model.primaryBaselineMedian
                )
                .frame(height: 73)
                .frame(maxWidth: .infinity)

                HStack {
                    Text("일요일")
                    Spacer()
                    Text("토요일")
                }
                .colloText(Collo.Font.caption02_300, Collo.Color.gray600, size: 10)

                // Action Btn (98:21629)
                NavigationLink {
                    FamilyPickerView(model: model)
                } label: {
                    HStack(spacing: Collo.Space.s1) {
                        Text("가족 모두 보기")
                            .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Collo.Color.gray700)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
            }

            healthFeedbackBox
        }
        .padding(Collo.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Collo.Color.gray00,
            in: RoundedRectangle(cornerRadius: Collo.Radius.small)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Collo.Radius.small)
                .stroke(Collo.Color.gray200, lineWidth: 1)
        )
    }

    // 카드 문구는 리포트 상태에서만 나온다. 진단·위험군 표현은 만들지 않는다.
    private var summary: (caption: String, headline: String, detail: String?) {
        guard let report = model.report else {
            return ("아직 불러오지 못했어요", "당겨서 다시 시도해보세요", nil)
        }
        switch report.state {
        case "EMPTY":
            return ("이번 주 기록", report.emptyMessage ?? "이번 기간에 분석된 통화가 없어요", nil)
        case "BASELINE_COLLECTING":
            return (
                "기준선 수집 중",
                "아직 비교할 기준이 모이지 않았어요",
                "같은 시간대 통화가 4주에 걸쳐 쌓이면 변화를 비교할 수 있어요"
            )
        default:
            guard let signal = report.promotedSignals.first, let text = signal.summaryText else {
                return ("이번 주 기록", "특별히 눈에 띄는 변화는 없어요", nil)
            }
            return ("이번 주 기록", text, report.advisory)
        }
    }

    private var analyzedCountText: String {
        guard let report = model.report else { return "분석된 통화 정보 없음" }
        return "이번 주 분석된 통화 \(report.analyzedCallCount)건"
    }

    // MARK: - 건강 피드백 (98:21630)

    private var healthFeedbackBox: some View {
        HStack(alignment: .top, spacing: Collo.Space.s2) {
            Image(systemName: "cross.fill")
                .font(.system(size: 12))
                .foregroundStyle(Collo.Color.gray00)
                .frame(width: 24, height: 24)
                .background(Collo.Color.green, in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: Collo.Space.s2) {
                HStack {
                    Text("건강 피드백")
                        .colloText(Collo.Font.body01_100, Collo.Color.gray800, size: 16)
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(Collo.Color.gray600)
                }
                Text(feedbackHeadline)
                    .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Collo.Space.s1) {
                    Text("최근 기록")
                    Text(lastCallText)
                }
                .colloText(Collo.Font.body02_100, Collo.Color.gray600, size: 14)
            }
        }
        .padding(Collo.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Collo.Color.gray100,
            in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
        )
    }

    // 통화에서 당사자가 실제로 말한 항목만 쓴다. 없으면 없다고 적는다.
    private var feedbackHeadline: String {
        guard let items = model.report?.conversationItems else { return "아직 기록이 없어요" }
        let mentioned = ["symptom", "sleep", "medication", "activity"]
            .compactMap { items[$0]?.first }
        return mentioned.first ?? "이번 주 통화에서 언급된 항목이 없어요"
    }

    private var lastCallText: String {
        guard let days = model.daysSinceLastCall else { return "통화 없음" }
        return days == 0 ? "오늘 통화" : "\(days)일 전 통화"
    }

    // MARK: - Tab Bar (98:21642)

    private var bodyTabBar: some View {
        HStack(spacing: 0) {
            ForEach(BodyTab.allCases, id: \.self) { tab in
                let isSelected = tab == selectedTab
                Button { selectedTab = tab } label: {
                    Text(tab.rawValue)
                        .colloText(
                            Collo.Font.body02_100,
                            isSelected ? Collo.Color.gray900 : Collo.Color.gray600,
                            size: 14
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            isSelected ? Collo.Color.gray00 : Collo.Color.gray300,
                            in: RoundedRectangle(cornerRadius: Collo.Radius.large)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Collo.Space.s1)
        .background(
            Collo.Color.gray300,
            in: RoundedRectangle(cornerRadius: Collo.Radius.large)
        )
    }

    // MARK: - 질문 미리보기

    private var questionList: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            if model.questions.isEmpty {
                emptyRow("오늘 준비된 질문이 없어요")
            }
            ForEach(Array(model.questions.enumerated()), id: \.element.id) { index, question in
                HStack(alignment: .top, spacing: Collo.Space.s2) {
                    Text("\(index + 1)")
                        .colloText(Collo.Font.body02_100, Collo.Color.gray600, size: 14)
                    Text(question.text)
                        .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Collo.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Collo.Color.gray100,
                    in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                )
            }
            Text("질환 프로필 기반 · 의료 지시 아님")
                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
        }
    }

    // MARK: - 전화 로그 (98:21643)

    private var callLogList: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            if model.calls.isEmpty {
                emptyRow("아직 통화 기록이 없어요")
            }
            // 145:5408 / 145:5420. 한 줄에 아바타·이름·수단·시점을 담는다.
            ForEach(model.calls) { call in
                HStack(spacing: Collo.Space.s3) {
                    FamilyAvatarCircle()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.subjectName)
                            .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 18)
                        HStack(spacing: 6) {
                            Image(systemName: "iphone")
                                .font(.system(size: 12))
                            Text(stateLabel(call.state))
                        }
                        .colloText(Collo.Font.body02_200, Collo.Color.gray700, size: 14)
                    }
                    Spacer(minLength: Collo.Space.s2)
                    Text(dayLabel(for: call))
                        .colloText(Collo.Font.body02_200, Collo.Color.gray700, size: 14)
                }
                .padding(.horizontal, Collo.Space.s2)
                .frame(height: 75)
                .frame(maxWidth: .infinity)
                // 반경 10은 피그마가 토큰 없이 직접 쓴 값이다(`--badge/medium`은 6).
                .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func dayLabel(for call: CollogAPI.CallSummary) -> String {
        guard let date = call.startedAtDate else { return "날짜 미상" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "오늘" }
        if calendar.isDateInYesterday(date) { return "어제" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "MM/dd(E)"
        return formatter.string(from: date)
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "ANALYZED": return "분석 완료"
        case "ANALYSIS_EXCLUDED": return "분석 제외"
        case "ANALYSIS_FAILED": return "분석 실패"
        case "ENDED": return "분석 대기"
        case "DECLINED": return "거절"
        default: return state
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Collo.Space.s4)
    }
}

// MARK: - 전화 목록 아바타 (145:5411)

// 피그마는 50pt 원에 그라데이션만 채우고 사진·이니셜을 넣지 않는다. 서버에도 프로필
// 이미지가 없으므로 같은 형태를 그대로 쓴다.
struct FamilyAvatarCircle: View {
    var size: CGFloat = 50

    var body: some View {
        Circle()
            .fill(Collo.Gradients.avatar)
            .frame(width: size, height: size)
    }
}

// MARK: - 추이 그래프 (98:21622)

// 피그마의 정적 SVG 대신 서버 acousticTrends를 그린다.
// 「선형 그래프 넣기 (날짜별로 달라지는 것이 보이게 하기)」 메모(92:5817)를 따른다.
struct TrendLineChart: View {
    let points: [CollogAPI.Report.TrendPoint]
    /// 기준선 중앙값. 피그마의 옅은 회색 참조선(grey/300)이 이 값이다. 서버가 기준선을
    /// 아직 못 세웠으면 nil이고, 그때는 참조선을 그리지 않는다.
    var baselineMedian: Double?

    /// 끝점 원과 선 굵기가 잘리지 않도록 위아래로 비워두는 여백.
    private let verticalInset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            if points.count >= 2 {
                ZStack(alignment: .topLeading) {
                    if let median = baselineMedian {
                        let y = self.y(for: median, in: geo.size)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(
                            Collo.Color.gray300,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                    }

                    smoothPath(in: geo.size)
                        .stroke(
                            Collo.Color.green,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )

                    // 마지막 측정값 강조 (98:21622). 옅은 테두리가 선 위에 겹쳐도 점이 묻히지 않게 한다.
                    if let last = positions(in: geo.size).last {
                        Circle()
                            .fill(Collo.Color.gray300)
                            .frame(width: 14, height: 14)
                            .position(last)
                        Circle()
                            .fill(Collo.Color.green)
                            .frame(width: 8, height: 8)
                            .position(last)
                    }
                }
            } else {
                Text("기준선 수집 중")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 값 축의 범위. 참조선이 그려질 때는 그 값까지 담아야 화면 밖으로 나가지 않는다.
    private var bounds: (min: Double, max: Double) {
        let values = points.map(\.value) + [baselineMedian].compactMap { $0 }
        return (values.min() ?? 0, values.max() ?? 1)
    }

    private func y(for value: Double, in size: CGSize) -> CGFloat {
        let (minValue, maxValue) = bounds
        let span = maxValue - minValue
        // 모든 값이 같으면 0으로 나누지 않고 가운데 수평선을 그린다.
        let ratio = span == 0 ? 0.5 : (value - minValue) / span
        let usable = max(size.height - verticalInset * 2, 1)
        return size.height - verticalInset - CGFloat(ratio) * usable
    }

    private func positions(in size: CGSize) -> [CGPoint] {
        let stepX = points.count > 1 ? size.width / CGFloat(points.count - 1) : 0
        return points.enumerated().map { index, point in
            CGPoint(x: CGFloat(index) * stepX, y: y(for: point.value, in: size))
        }
    }

    /// 피그마 그래프는 꺾인 직선이 아니라 완만한 곡선이다. 측정값을 그대로 지나가면서
    /// 곡선으로 잇기 위해 Catmull-Rom 스플라인을 3차 베지에로 바꿔 그린다. 점 위치는
    /// 건드리지 않으므로 없는 값을 만들어내지 않는다.
    private func smoothPath(in size: CGSize) -> Path {
        let pts = positions(in: size)
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for index in 0..<(pts.count - 1) {
            let p0 = pts[max(index - 1, 0)]
            let p1 = pts[index]
            let p2 = pts[index + 1]
            let p3 = pts[min(index + 2, pts.count - 1)]
            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        return path
    }
}

// MARK: - 가족 모두 보기

// 건강 주체를 바꾸고 바로 전화를 건다.
struct FamilyPickerView: View {
    @ObservedObject var model: HomeDashboardModel
    @ObservedObject private var session = AppSession.shared
    @ObservedObject private var callCenter = VoipCallCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if session.members.isEmpty {
                Text("연결된 가족이 없어요. 초대를 먼저 만든다.")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
            }
            ForEach(session.members) { member in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name)
                            .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                        Text(statusText(member.status))
                            .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    }
                    Spacer()
                    if let userId = member.userId {
                        Button {
                            Task {
                                await model.selectSubject(id: userId, name: member.name)
                                dismiss()
                            }
                        } label: {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            callCenter.startOutgoingCall(calleeId: userId, name: member.name)
                            dismiss()
                        } label: {
                            Image(systemName: "phone.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Collo.Color.green)
                    }
                }
            }
        }
        .navigationTitle("가족 모두 보기")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await session.refreshMembers() }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "CONSENT_GRANTED": return "동의 완료"
        case "CONSENT_PENDING": return "동의 대기"
        case "CONSENT_DENIED": return "동의 거절"
        case "INVITED": return "초대됨"
        default: return status
        }
    }
}
