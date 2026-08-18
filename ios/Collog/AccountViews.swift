import SwiftUI

// 피그마 `계정 정보 화면`(92:5763).
//
// 피그마의 `이메일`, `생년월일`은 현재 서버 `UserView`에 없는 필드다(id/role/name/phone/
// familyId만 있다). 없는 값을 빈칸으로 만들어 두지 않고, 서버가 실제로 주는 항목만 쓴다.
struct AccountInfoView: View {
    @ObservedObject private var session = AppSession.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                block("기본 정보") {
                    if let user = session.user {
                        row("이름", user.name)
                        row("전화", user.phone)
                        row("역할", user.role == "CHILD" ? "자녀" : "부모")
                    } else {
                        Text("로그인 정보가 없어요")
                            .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                    }
                }

                block("음성 데이터 처리") {
                    Text("원본 음성 데이터는 다음 정책을 따릅니다.")
                        .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)
                    ForEach(
                        [
                            "음향 신호 추출 후 원본 오디오는 즉시 폐기됩니다.",
                            "저장되는 것은 음향 지표와 대화 텍스트뿐입니다.",
                            "이 설정은 변경할 수 없습니다.",
                        ],
                        id: \.self
                    ) { line in
                        HStack(alignment: .top, spacing: Collo.Space.s2) {
                            Text("•").colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                            Text(line)
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray800, size: 12)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }

                block("개인정보 및 보안") {
                    NavigationLink("동의 관리") { ConsentManageView() }
                        .colloText(Collo.Font.body02_100, Collo.Color.orange, size: 14)
                }

                Text("이메일·생년월일은 서버 계정 모델에 아직 없어요. 추가되면 여기에 표시돼요.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("계정 정보")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
            Spacer()
            Text(value)
                .colloText(Collo.Font.body02_100, Collo.Color.gray900, size: 14)
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

// 피그마 `설정 탭 화면`(92:5549) + `설정 화면`(92:5696).
struct SettingsView: View {
    @ObservedObject var model: HomeDashboardModel
    @ObservedObject private var session = AppSession.shared
    @ObservedObject private var callCenter = VoipCallCenter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                VStack(spacing: 0) {
                    navRow("계정 정보") { AccountInfoView() }
                    Divider()
                    navRow("나의 건강 프로필") {
                        HealthProfileView(
                            subjectId: model.subjectId ?? session.user?.id ?? "",
                            subjectName: model.subjectName.isEmpty
                                ? (session.user?.name ?? "나") : model.subjectName,
                            isSelf: model.subjectId == session.user?.id
                        )
                    }
                    Divider()
                    navRow("가족 구성원 관리") { FamilyMembersView() }
                    Divider()
                    // 부모 계정은 자녀가 만든 초대 코드를 입력해 가족에 합류한다.
                    if session.user?.role == "PARENT" {
                        navRow("초대 코드 입력") { InvitationAcceptView() }
                        Divider()
                    }
                    navRow("가족 공유 데이터 범위") { FamilyShareView() }
                    Divider()
                    navRow("공유 자료 열람") { SharedMaterialsView(model: model) }
                    Divider()
                    navRow("동의 관리") { ConsentManageView() }
                }
                .background(
                    Collo.Color.gray100,
                    in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                )

                block("개인정보 및 건강정보 처리 안내") {
                    row("수집 항목", "통화 음향 지표, 건강 대화 항목")
                    row("원본 오디오", "통화 종료 후 즉시 폐기")
                    row("공유 범위", "초대된 가족에 한해 허용된 자료만 열람 가능")
                    row("분석 조건", "부모의 사전 동의 완료 시에만 분석 활성화")
                }

                developerBlock

                Button("로그아웃", role: .destructive) { session.logout() }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        Collo.Color.gray100,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.medium)
                    )
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("설정")
        .background(Collo.Color.gray00)
    }

    // 실기기 디버깅용. APNs 검증에 필요한 토큰을 눈으로 확인한다.
    private var developerBlock: some View {
        DisclosureGroup("개발 정보") {
            VStack(alignment: .leading, spacing: Collo.Space.s2) {
                TokenRow(title: "VoIP 토큰", token: callCenter.voipToken)
                TokenRow(title: "APNs 토큰", token: callCenter.apnsToken)
                if !callCenter.events.isEmpty {
                    Button("전체 로그 복사") {
                        UIPasteboard.general.string =
                            callCenter.events.reversed().joined(separator: "\n")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                ForEach(Array(callCenter.events.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private func navRow<Destination: View>(
        _ title: String,
        @ViewBuilder _ destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack {
                Text(title)
                    .colloText(Collo.Font.body02_100, Collo.Color.gray900, size: 14)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Collo.Color.gray600)
            }
            .padding(Collo.Space.s4)
        }
        .buttonStyle(.plain)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
            Spacer(minLength: Collo.Space.s3)
            Text(value)
                .colloText(Collo.Font.caption01_200, Collo.Color.gray900, size: 12)
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
