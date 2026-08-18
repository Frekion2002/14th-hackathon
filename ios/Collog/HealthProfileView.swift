import SwiftUI

// 피그마 `본인 프로필 생성 화면`(92:5339)과 `질환 프로필 등록 화면`(92:4875).
// 두 화면은 대상(본인/부모)만 다르고 구조가 같아서 하나로 만들고 제목만 바꾼다.
//
// 주의: 현재 서버 `PUT /parents/{id}/profile`이 받는 질환 코드는 5개(당뇨·고혈압·고지혈증·
// 천식·비만)뿐이다. 피그마의 `건망증`, `호흡기 질환`, `비염`은 서버 enum에 없어서 보내면
// 422로 거절된다. 없는 코드를 만들어 보내지 않고, 확장은 implementation-plan-v2 Phase 1의
// HealthCondition/HealthConcern 모델이 들어온 뒤에 연결한다.
struct HealthProfileView: View {
    let subjectId: String
    let subjectName: String
    /// 본인 프로필이면 true. 제목과 안내 문구가 달라진다.
    let isSelf: Bool

    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                header

                Text(isSelf ? "질환이나 걱정되는 부분을 관리해 보아요" : "부모님 건강 프로필 등록")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 16)
                Text("등록된 질환은 통화 전 건강 질문과 신호 해석에 활용됩니다.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray700, size: 12)

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    chips
                }

                Text("선택한 항목은 언제든지 수정할 수 있습니다.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)

                // 피그마에는 있으나 서버 계약에 아직 없는 항목을 숨기지 않고 상태를 밝힌다.
                VStack(alignment: .leading, spacing: Collo.Space.s1) {
                    Text("아직 등록할 수 없는 항목")
                        .colloText(Collo.Font.body02_100, Collo.Color.gray800, size: 14)
                    Text("건망증·호흡기 질환·비염 같은 걱정 항목과 복용약은 서버 프로필 모델이 확장되면 열려요.")
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Collo.Space.s3)
                .background(
                    Collo.Color.gray100,
                    in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium)
                )

                if let savedMessage {
                    Text(savedMessage).colloText(Collo.Font.body02_300, Collo.Color.green, size: 14)
                }
                if let errorMessage {
                    Text(errorMessage).colloText(Collo.Font.body02_300, .red, size: 14)
                }
            }
            .padding(Collo.Space.screen)
        }
        .safeAreaInset(edge: .bottom) { saveButton }
        .navigationTitle(isSelf ? "본인 프로필" : "질환 프로필 등록")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: Collo.Space.s2) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Collo.Color.avatarStroke)
            Text(subjectName)
                .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)
            Spacer()
        }
    }

    private var chips: some View {
        // 고정 5개라 단순 격자로 충분하다.
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: Collo.Space.s2
        ) {
            ForEach(CollogAPI.conditionCodes, id: \.code) { item in
                let isOn = selected.contains(item.code)
                Button {
                    if isOn { selected.remove(item.code) } else { selected.insert(item.code) }
                } label: {
                    Text(item.label)
                        .colloText(
                            Collo.Font.body02_100,
                            isOn ? Collo.Color.gray00 : Collo.Color.gray800,
                            size: 14
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            isOn ? Collo.Color.orange : Collo.Color.gray100,
                            in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var saveButton: some View {
        Button { Task { await save() } } label: {
            Text(isSaving ? "저장 중…" : "저장하기")
                .colloText(Collo.Font.body01_100, Collo.Color.gray00, size: 16)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    isSaving ? Collo.Color.gray300 : Collo.Color.orange,
                    in: RoundedRectangle(cornerRadius: Collo.Radius.medium)
                )
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .padding(.horizontal, Collo.Space.screen)
        .padding(.vertical, Collo.Space.s3)
        .background(Collo.Color.gray00)
    }

    private func load() async {
        defer { isLoading = false }
        do {
            selected = Set(try await CollogAPI.profile(parentId: subjectId).conditions)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        savedMessage = nil
        defer { isSaving = false }
        do {
            let updated = try await CollogAPI.updateProfile(
                parentId: subjectId,
                conditions: Array(selected).sorted()
            )
            selected = Set(updated.conditions)
            savedMessage = "저장했어요"
        } catch {
            // 서버는 동의 전 프로필 저장을 409로 막는다. 그 문구를 그대로 보여준다.
            errorMessage = error.localizedDescription
        }
    }
}
