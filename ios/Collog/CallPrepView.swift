import SwiftUI

// 피그마 `전화 걸기 화면`(92:4783) / `홈 화면`(92:5930) / `부모 기준 홈 화면`(92:4757).
// 셋은 같은 구조에 대상만 다르다. 가족 목록에서 밀어서 전화하고, 아래에 오늘의 질문을 미리 본다.
struct CallPrepView: View {
    @ObservedObject private var session = AppSession.shared
    @ObservedObject private var callCenter = VoipCallCenter.shared

    @State private var questions: [CollogAPI.Question] = []
    @State private var questionTargetName = ""
    @State private var conditions: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Text("\(session.user?.name ?? "우리")네 가족")
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)

                Text("가족에게 전화하기")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

                if session.members.isEmpty {
                    Text("아직 등록 된 가족 멤버가 없어요")
                        .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Collo.Space.s4)
                        .background(
                            Collo.Color.gray100,
                            in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                        )
                    NavigationLink("가족 초대하기") { InviteView() }
                        .colloText(Collo.Font.body02_100, Collo.Color.orange, size: 14)
                }

                ForEach(session.members) { member in
                    memberRow(member)
                }

                questionPreview

                if let errorMessage {
                    Text(errorMessage).colloText(Collo.Font.body02_300, .red, size: 14)
                }
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("전화 걸기")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - 「밀어서 전화하기」 (92:4783)

    private func memberRow(_ member: CollogAPI.Member) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                Text(statusText(member.status))
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
            }
            Spacer()
            if let userId = member.userId {
                SlideToCall(label: "밀어서 전화하기") {
                    callCenter.startOutgoingCall(calleeId: userId, name: member.name)
                }
            } else {
                Text("초대 수락 대기")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
            }
        }
        .padding(Collo.Space.s3)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
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

    // MARK: - 오늘의 건강 질문 미리보기 (92:4783)

    private var questionPreview: some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text("오늘의 건강 질문 미리보기")
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)

            if questionTargetName.isEmpty {
                Text("질문을 볼 가족을 먼저 연결해주세요")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
            } else {
                Text("통화 전 확인해보세요 (\(questionTargetName))")
                    .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
            }

            if questions.isEmpty && !questionTargetName.isEmpty {
                Text("오늘 준비된 질문이 없어요")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
            }

            ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                HStack(alignment: .top, spacing: Collo.Space.s2) {
                    Text("\(index + 1)")
                        .colloText(Collo.Font.body02_100, Collo.Color.gray600, size: 14)
                    Text(question.text)
                        .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(Collo.Space.s3)
                .background(
                    Collo.Color.gray00,
                    in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium)
                )
            }

            // 피그마는 `질환 프로필(고혈압·당뇨) 기반`처럼 실제 질환명을 적는다.
            // 프로필이 비어 있으면 질환명을 지어내지 않는다.
            Text(profileFooter)
                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)

            NavigationLink {
                QuestionDetailView(
                    questions: questions,
                    targetName: questionTargetName,
                    conditions: conditions
                )
            } label: {
                HStack {
                    Text("질문 전체 보기")
                        .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Collo.Color.gray700)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }

    private var profileFooter: String {
        let labels = conditions.compactMap { code in
            CollogAPI.conditionCodes.first { $0.code == code }?.label
        }
        return labels.isEmpty
            ? "질환 프로필 미등록 · 의료 지시 아님"
            : "질환 프로필(\(labels.joined(separator: "·"))) 기반 · 의료 지시 아님"
    }

    private func load() async {
        await session.refreshMembers()
        guard let member = session.members.first(where: { $0.userId != nil }),
              let targetId = member.userId else {
            questions = []
            questionTargetName = ""
            return
        }
        questionTargetName = member.name
        do {
            questions = try await CollogAPI.dailyQuestions(parentId: targetId)
            conditions = try await CollogAPI.profile(parentId: targetId).conditions
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// 「밀어서 전화하기」. 실수 발신을 막으려고 탭이 아니라 드래그로 확정한다.
struct SlideToCall: View {
    let label: String
    let action: () -> Void

    @State private var offset: CGFloat = 0
    private let width: CGFloat = 140
    private let knob: CGFloat = 36

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Collo.Color.gray200)
            Text(label)
                .colloText(Collo.Font.caption01_200, Collo.Color.gray700, size: 12)
                .frame(width: width, alignment: .center)
            Circle()
                .fill(Collo.Color.orange)
                .overlay(
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Collo.Color.gray00)
                )
                .frame(width: knob, height: knob)
                .offset(x: offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = min(max(0, value.translation.width), width - knob)
                        }
                        .onEnded { _ in
                            if offset > (width - knob) * 0.7 { action() }
                            withAnimation { offset = 0 }
                        }
                )
        }
        .frame(width: width, height: knob)
    }
}

// 피그마 `질문 텍스트 표시 화면`(92:4942) + `통화 전 질문 안내 화면`(92:4916).
struct QuestionDetailView: View {
    let questions: [CollogAPI.Question]
    let targetName: String
    let conditions: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Text("오늘의 건강 질문")
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)
                Text("통화 전 아래 질문을 참고해 대화를 준비하세요.")
                    .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)

                if !targetName.isEmpty {
                    VStack(alignment: .leading, spacing: Collo.Space.s2) {
                        Text("\(targetName) 질환 프로필")
                            .colloText(Collo.Font.body02_100, Collo.Color.gray800, size: 14)
                        if conditionLabels.isEmpty {
                            Text("등록된 질환이 없어요")
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        } else {
                            HStack(spacing: Collo.Space.s1) {
                                ForEach(conditionLabels, id: \.self) { label in
                                    Text(label)
                                        .colloText(
                                            Collo.Font.caption01_100, Collo.Color.blue600, size: 12
                                        )
                                        .padding(.horizontal, Collo.Space.s2)
                                        .frame(height: 26)
                                        .background(
                                            Collo.Color.blue100,
                                            in: RoundedRectangle(
                                                cornerRadius: Collo.Radius.badgeMedium
                                            )
                                        )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Collo.Space.s4)
                    .background(
                        Collo.Color.gray100,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                    )
                }

                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: Collo.Space.s1) {
                        // 서버가 준 질환 코드가 있으면 그것만 카테고리로 쓴다.
                        if let code = question.conditionCode,
                           let label = CollogAPI.conditionCodes.first(where: { $0.code == code })?
                            .label {
                            Text(label)
                                .colloText(Collo.Font.caption01_100, Collo.Color.orange, size: 12)
                        }
                        Text(question.text)
                            .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(question.usesRemoteTTS ? "음성 안내 준비됨" : "기기 음성으로 안내")
                            .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Collo.Space.s4)
                    .background(
                        Collo.Color.gray100,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                    )
                }

                Text("질환 프로필 기반으로 생성된 질문입니다. 진단이나 의료 판단을 포함하지 않습니다.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                Text("원본 오디오는 저장되지 않으며 통화 후 즉시 폐기됩니다.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("오늘의 건강 질문")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
    }

    private var conditionLabels: [String] {
        conditions.compactMap { code in
            CollogAPI.conditionCodes.first { $0.code == code }?.label
        }
    }
}
