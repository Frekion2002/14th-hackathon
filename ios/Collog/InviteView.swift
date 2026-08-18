import SwiftUI
import UIKit

// 피그마 `부모 초대 화면`(92:4846) + `초대하기 화면`(92:5442).
// 자녀가 부모를 초대하고, 서버가 준 6자리 코드를 공유한다.
struct InviteView: View {
    @ObservedObject private var session = AppSession.shared

    @State private var name = ""
    @State private var relation = "MOTHER"
    @State private var invitation: CollogAPI.Invitation?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Text("부모 초대")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 16)
                Text("초대를 받은 부모님은 동의 내용을 확인한 뒤 수락 여부를 선택할 수 있습니다.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray700, size: 12)
                    .fixedSize(horizontal: false, vertical: true)

                targetSection

                if let invitation {
                    shareSection(invitation)
                }

                noticeSection

                if let errorMessage {
                    Text(errorMessage).colloText(Collo.Font.body02_300, .red, size: 14)
                }
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("부모 초대")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
    }

    // MARK: - 초대 대상 정보 (92:4846)

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("초대 대상 정보")
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

            TextField("성함", text: $name)
                .textContentType(.name)
                .padding(Collo.Space.s3)
                .background(
                    Collo.Color.gray100,
                    in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium)
                )

            Picker("관계", selection: $relation) {
                Text("어머니").tag("MOTHER")
                Text("아버지").tag("FATHER")
            }
            .pickerStyle(.segmented)

            Button { Task { await createInvitation() } } label: {
                Text(isWorking ? "초대 만드는 중…" : "초대 만들기")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray00, size: 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        canCreate ? Collo.Color.orange : Collo.Color.gray300,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.medium)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
    }

    // MARK: - 초대하기 (92:5442) — 문자 / 카카오톡 / 초대 코드

    private func shareSection(_ invitation: CollogAPI.Invitation) -> some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("초대 하기")
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

            HStack {
                Text("초대 코드")
                    .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
                Spacer()
                Text(invitation.code)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(Collo.Color.orange)
            }

            // 문자와 카카오톡 모두 같은 초대 문구를 전달하는 채널이다.
            // 카카오 SDK는 아직 붙지 않아 시스템 공유 시트로 보낸다.
            ShareLink(item: invitation.shareText) {
                rowLabel("문자·카카오톡으로 초대하기", icon: "square.and.arrow.up")
            }

            Button {
                UIPasteboard.general.string = invitation.code
            } label: {
                rowLabel("초대 코드 복사하기", icon: "doc.on.doc")
            }
            .buttonStyle(.plain)

            Button { Task { await resend(invitation) } } label: {
                rowLabel("초대 코드 다시 발급", icon: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Text("상태 \(statusLabel(invitation.status))")
                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private func rowLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: Collo.Space.s2) {
            Image(systemName: icon).foregroundStyle(Collo.Color.gray700)
            Text(title)
                .colloText(Collo.Font.body02_100, Collo.Color.gray800, size: 14)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Collo.Color.gray600)
        }
        .padding(Collo.Space.s3)
        .background(Collo.Color.gray00, in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium))
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "PENDING": return "수락 대기 중"
        case "ACCEPTED": return "수락 완료"
        case "EXPIRED": return "만료됨"
        default: return status
        }
    }

    // MARK: - 건강정보 수집·이용 안내 (92:4846)

    private var noticeSection: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("건강정보 수집·이용 안내")
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
            ForEach(Self.notices, id: \.title) { notice in
                VStack(alignment: .leading, spacing: Collo.Space.s1) {
                    Text(notice.title)
                        .colloText(Collo.Font.body02_100, Collo.Color.gray800, size: 14)
                    Text(notice.body)
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray700, size: 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private static let notices: [(title: String, body: String)] = [
        ("수집 항목", "통화 음성에서 기침 이벤트, 발화 속도, 휴지 비율, 기본주파수 변동을 추출합니다. 대화 내용은 증상·복약·활동·수면 언급 등 건강 관련 항목으로 구조화됩니다."),
        ("이용 목적", "추출된 지표와 구조화 결과는 개인의 과거 통화와 비교한 주간·월간 변화 리포트 생성에만 사용됩니다. 집단 평균 비교나 위험군 판정에는 사용되지 않습니다."),
        ("원본 오디오 폐기", "음향 지표 계산이 완료되면 원본 오디오는 즉시 폐기됩니다. 장기 보관하지 않습니다."),
        ("열람 권한", "동의 완료 후 부모님은 본인의 건강 리포트를 직접 열람할 수 있습니다. 동의하지 않은 경우 분석 기능은 활성화되지 않습니다."),
        ("공유 범위", "초대된 가족 구성원은 허용된 범위 내의 건강 타임라인 자료만 열람할 수 있습니다. 의료기관 시스템과는 연동되지 않습니다."),
    ]

    private func createInvitation() async {
        guard let familyId = session.user?.familyId else {
            errorMessage = "가족 정보가 없어요. 다시 로그인해주세요."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            invitation = try await CollogAPI.createInvitation(
                familyId: familyId,
                name: name.trimmingCharacters(in: .whitespaces),
                relation: relation
            )
            await session.refreshMembers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resend(_ current: CollogAPI.Invitation) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            invitation = try await CollogAPI.resendInvitation(invitationId: current.invitationId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// 피그마 `초대 확인 화면`(92:5472) + `초대 수락 및 프로필 저장 화면`(92:5482).
// 부모가 받은 코드를 입력해 가족에 합류한다.
struct InvitationAcceptView: View {
    @ObservedObject private var session = AppSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var accepted: CollogAPI.InvitationAccepted?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Image("HomeCharacter")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)

                Text("자녀와 함께 건강 데이터를 관리해 보세요!")
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)
                Text("받으신 초대 코드를 입력하면 가족에 연결돼요.")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)

                if let accepted {
                    VStack(alignment: .leading, spacing: Collo.Space.s2) {
                        Text("초대를 수락했어요")
                            .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                        Text(statusText(accepted.status))
                            .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Collo.Space.s4)
                    .background(
                        Collo.Color.gray100,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                    )
                } else {
                    TextField("6자리 초대 코드", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding(Collo.Space.s4)
                        .background(
                            Collo.Color.gray100,
                            in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                        )

                    Button { Task { await accept() } } label: {
                        Text(isWorking ? "확인 중…" : "초대 수락하기")
                            .colloText(Collo.Font.body01_100, Collo.Color.gray00, size: 16)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                code.count == 6 && !isWorking
                                    ? Collo.Color.orange : Collo.Color.gray300,
                                in: RoundedRectangle(cornerRadius: Collo.Radius.medium)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(code.count != 6 || isWorking)
                }

                if let errorMessage {
                    Text(errorMessage).colloText(Collo.Font.body02_300, .red, size: 14)
                }
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("초대 확인")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
    }

    // 수락 직후 상태는 서버가 `AWAITING_CONSENT`로 준다. 동의가 먼저다.
    private func statusText(_ status: String) -> String {
        status == "AWAITING_CONSENT"
            ? "이제 건강정보 동의를 완료하면 분석이 시작돼요."
            : status
    }

    private func accept() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            accepted = try await CollogAPI.acceptInvitation(code: code)
            await session.refreshMembers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
