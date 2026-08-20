import SwiftUI

// 피그마 `가족 구성원 관리 화면`(92:5299).
struct FamilyMembersView: View {
    @ObservedObject private var session = AppSession.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s3) {
                if session.members.isEmpty {
                    Text("아직 등록된 가족이 없어요")
                        .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                }
                ForEach(session.members) { member in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: Collo.Space.s1) {
                            Text("\(member.name) (\(relationLabel(member.relation)))")
                                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                            Text(detailText(member))
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        }
                        Spacer()
                        badge(member.status)
                    }
                    .padding(Collo.Space.s4)
                    .background(
                        Collo.Color.gray100,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                    )
                }

                NavigationLink { InviteView() } label: {
                    Text("가족 초대하기")
                        .colloText(Collo.Font.body01_100, Collo.Color.gray00, size: 16)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            Collo.Color.orange,
                            in: RoundedRectangle(cornerRadius: Collo.Radius.medium)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("가족 구성원 관리")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .refreshable { await session.refreshMembers() }
        .task { await session.refreshMembers() }
    }

    private func relationLabel(_ relation: String) -> String {
        switch relation {
        case "MOTHER": return "어머니"
        case "FATHER": return "아버지"
        default: return relation
        }
    }

    private func detailText(_ member: CollogAPI.Member) -> String {
        switch member.status {
        case "CONSENT_GRANTED": return "동의 완료 · 리포트 열람 허용"
        case "CONSENT_PENDING": return "동의 대기 중"
        case "CONSENT_DENIED": return "동의하지 않음 · 분석 비활성"
        case "INVITED": return "초대 수락 대기 중"
        default: return member.status
        }
    }

    private func badge(_ status: String) -> some View {
        let granted = status == "CONSENT_GRANTED"
        return Text(granted ? "동의됨" : "대기 중")
            .colloText(
                Collo.Font.caption01_100,
                granted ? Collo.Color.blue600 : Collo.Color.gray700,
                size: 12
            )
            .padding(.horizontal, Collo.Space.s2)
            .frame(height: 26)
            .background(
                granted ? Collo.Color.blue100 : Collo.Color.gray200,
                in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium)
            )
    }
}

// 피그마 `가족 공유 화면`(92:5500) + `공유 완료 확인 화면`(92:5581).
//
// 서버에 공유 범위(scope) 설정 endpoint가 아직 없다. 그래서 현재 실제로 적용 중인 규칙만
// 있는 그대로 보여주고, 사용자가 바꿀 수 있는 것처럼 만들지 않는다.
// 범위 편집은 implementation-plan-v2 Phase 5의 공유 scope API가 들어온 뒤 연결한다.
struct FamilyShareView: View {
    @ObservedObject private var session = AppSession.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Text("가족 공유")
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)
                Text("공유할 가족 구성원을 선택하고 열람 권한을 확인하세요.")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)

                block("공유 대상") {
                    if session.members.isEmpty {
                        Text("연결된 가족이 없어요")
                            .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                    }
                    ForEach(session.members) { member in
                        HStack {
                            Text(member.name)
                                .colloText(Collo.Font.body02_100, Collo.Color.gray900, size: 14)
                            Spacer()
                            Text(
                                member.status == "CONSENT_GRANTED"
                                    ? "열람 권한: 리포트 · 타임라인"
                                    : "동의 전이라 열람 불가"
                            )
                            .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        }
                    }
                }

                block("공유 자료 범위") {
                    scopeRow("📋", "주간·월간 변화 리포트")
                    scopeRow("📅", "건강 타임라인 (최근 3개월)")
                    scopeRow("🔒", "원본 통화 내용 및 오디오는 공유되지 않습니다.")
                }

                block("열람 권한 안내") {
                    ForEach(
                        [
                            "초대된 가족은 허용된 범위의 자료만 열람할 수 있습니다.",
                            "공유 범위는 설정에서 언제든지 변경하거나 철회할 수 있습니다.",
                            "의료 진단이나 위험 판정은 포함되지 않습니다.",
                        ],
                        id: \.self
                    ) { line in
                        Text(line)
                            .colloText(Collo.Font.caption01_200, Collo.Color.gray700, size: 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("공유 범위 편집은 서버 API가 준비되면 열려요. 지금은 동의 여부에 따라 자동 적용됩니다.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("가족 공유")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .task { await session.refreshMembers() }
    }

    private func scopeRow(_ emoji: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Collo.Space.s2) {
            Text(emoji)
            Text(text)
                .colloText(Collo.Font.body02_300, Collo.Color.gray800, size: 14)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func block<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Collo.Space.s2) {
            Text(title)
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }
}

// 피그마 `공유 자료 열람 화면`(92:5627).
// 가족이 열람할 수 있는 범위를 실제 리포트/통화 데이터로 보여준다.
struct SharedMaterialsView: View {
    @ObservedObject var model: HomeDashboardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Text("공유 자료 열람")
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)

                block("공유 정보 안내") {
                    row("자료 범위", "주간·월간 건강 리포트, 건강 타임라인")
                    row("수신자", "초대된 가족 구성원")
                    row("열람 권한", "허용된 범위 내 읽기 전용")
                    row("원본 오디오", "수집 즉시 폐기, 보관하지 않음")
                }

                block("건강 리포트") {
                    if let report = model.report {
                        row("기간", "\(report.from) ~ \(report.to)")
                        row("분석된 통화", "\(report.analyzedCallCount)건")
                        if report.isReady {
                            ForEach(report.promotedSignals) { signal in
                                if let text = signal.summaryText {
                                    Text(text)
                                        .colloText(
                                            Collo.Font.body02_300, Collo.Color.gray800, size: 14
                                        )
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else {
                            Text("아직 비교할 기준선이 모이지 않아 변화 문장은 없어요")
                                .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                        }
                    } else {
                        Text("리포트를 불러오지 못했어요")
                            .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                    }
                }

                block("건강 타임라인") {
                    let recent = Array(model.calls.prefix(5))
                    if recent.isEmpty {
                        Text("공유할 통화 기록이 없어요")
                            .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                    }
                    ForEach(recent) { call in
                        HStack {
                            Text(dateLabel(call))
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                            Spacer()
                            Text(call.isAnalyzed ? "분석 완료" : "분석 없음")
                                .colloText(Collo.Font.body02_100, Collo.Color.gray800, size: 14)
                        }
                    }
                }

                Text("이 자료는 진단·치료 목적이 아닌 일상 변화 참고용입니다. 의료 판단은 전문의에게 확인하세요.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("공유 자료 열람")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .task { await model.loadInitial() }
    }

    private func dateLabel(_ call: CollogAPI.CallSummary) -> String {
        guard let date = call.startedAtDate else { return "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy. MM. dd"
        return formatter.string(from: date)
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

    private func block<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Collo.Space.s2) {
            Text(title)
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }
}
