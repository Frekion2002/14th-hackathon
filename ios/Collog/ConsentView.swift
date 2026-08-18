import SwiftUI

// 피그마 `동의 확인 화면`(92:5415). 문구는 피그마 그대로 쓰고, 실제 동의 항목/버전은
// 서버 `/v1/consents/document`에서 받는다. 서버는 `scrolledToEnd`와 `agreedItems`를
// 검증하므로 화면이 끝까지 스크롤됐는지 실제로 추적한다.
struct ConsentView: View {
    /// 동의가 끝나면 호출된다. 온보딩 흐름에서 다음 단계로 넘길 때 쓴다.
    var onGranted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var document: CollogAPI.ConsentDocument?
    @State private var agreedItems: Set<String> = []
    @State private var scrolledToEnd = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Collo.Space.s4) {
                    Text("건강정보 동의 확인")
                        .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 16)
                    Text("아래 내용을 확인하신 후 동의 여부를 선택해 주세요.")
                        .colloText(Collo.Font.caption01_200, Collo.Color.gray700, size: 12)

                    section(
                        "수집·이용 목적",
                        [
                            "통화 음성에서 기침 이벤트, 발화 속도, 휴지 비율, 기본주파수 변동을 추출합니다.",
                            "추출된 음향 지표와 대화 내용은 개인의 과거 통화 기준선과 비교하는 데만 사용됩니다.",
                            "질환 판정이나 의료 진단에는 사용되지 않습니다.",
                        ]
                    )

                    section(
                        "원본 오디오 처리 원칙",
                        [
                            "통화 분석 완료 후 원본 오디오는 즉시 폐기됩니다.",
                            "분석된 지표와 구조화된 대화 항목만 기록으로 보관됩니다.",
                            "저장된 데이터는 가족이 허용한 범위 내에서만 열람 가능합니다.",
                        ]
                    )

                    section(
                        "동의 범위 및 권리",
                        [
                            "동의는 언제든지 철회할 수 있으며, 철회 시 이후 분석은 즉시 중단됩니다.",
                            "동의 이전 통화에 대한 소급 분석은 수행되지 않습니다.",
                        ]
                    )

                    if let document {
                        // 서버가 요구하는 필수 항목. 전부 체크해야 GRANT가 통과한다.
                        VStack(alignment: .leading, spacing: Collo.Space.s2) {
                            Text("동의 항목")
                                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                            ForEach(document.requiredItems, id: \.self) { item in
                                Button {
                                    if agreedItems.contains(item) {
                                        agreedItems.remove(item)
                                    } else {
                                        agreedItems.insert(item)
                                    }
                                } label: {
                                    HStack(spacing: Collo.Space.s2) {
                                        Image(
                                            systemName: agreedItems.contains(item)
                                                ? "checkmark.square.fill" : "square"
                                        )
                                        .foregroundStyle(
                                            agreedItems.contains(item)
                                                ? Collo.Color.orange : Collo.Color.gray600
                                        )
                                        Text(item)
                                            .colloText(
                                                Collo.Font.body02_300, Collo.Color.gray800, size: 14
                                            )
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            Text("문서 버전 \(document.version) · 보관 기간 \(document.retentionPeriod)")
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        }
                        .padding(Collo.Space.s4)
                        .background(
                            Collo.Color.gray100,
                            in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                        )
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .colloText(Collo.Font.body02_300, .red, size: 14)
                    }

                    // 이 마커가 보이면 끝까지 읽은 것으로 본다.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { scrolledToEnd = true }
                }
                .padding(Collo.Space.screen)
            }
            .onChange(of: document?.version) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { actions }
        .navigationTitle("동의 확인")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .task { await loadDocument() }
    }

    private var canGrant: Bool {
        guard let document else { return false }
        return scrolledToEnd && agreedItems.count == document.requiredItems.count && !isWorking
    }

    private var actions: some View {
        VStack(spacing: Collo.Space.s2) {
            if !scrolledToEnd {
                Text("끝까지 읽어주세요")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
            }
            Button { Task { await submit("GRANT") } } label: {
                Text("동의하고 시작하기")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray00, size: 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        canGrant ? Collo.Color.orange : Collo.Color.gray300,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.medium)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canGrant)

            Button { Task { await submit("DENY") } } label: {
                Text("동의하지 않음")
                    .colloText(Collo.Font.body02_100, Collo.Color.gray700, size: 14)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: Collo.Radius.medium)
                            .stroke(Collo.Color.gray300, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
        }
        .padding(.horizontal, Collo.Space.screen)
        .padding(.vertical, Collo.Space.s3)
        .background(Collo.Color.gray00)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Collo.Space.s3) {
            Text(title)
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray800, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s3)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium)
                .stroke(Collo.Color.gray200, lineWidth: 1)
        )
    }

    private func loadDocument() async {
        do {
            document = try await CollogAPI.consentDocument()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit(_ decision: String) async {
        guard let document else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let record = try await CollogAPI.submitConsent(
                documentVersion: document.version,
                decision: decision,
                scrolledToEnd: scrolledToEnd,
                agreedItems: decision == "GRANT" ? Array(agreedItems) : []
            )
            if record.isGranted { onGranted?() }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// 피그마 `동의 관리 화면`(92:5733). 현재 동의 상태를 서버에서 읽어 보여준다.
struct ConsentManageView: View {
    @State private var record: CollogAPI.ConsentRecord?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Collo.Space.s4) {
                Text("현재 동의 상태")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray1000, size: 16)

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let record {
                    VStack(alignment: .leading, spacing: Collo.Space.s2) {
                        HStack {
                            Text("건강정보 수집·이용 동의")
                                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
                            Spacer()
                            Text(record.isGranted ? "동의 완료" : "동의 안 함")
                                .colloText(
                                    Collo.Font.caption01_100,
                                    record.isGranted ? Collo.Color.blue600 : Collo.Color.gray700,
                                    size: 12
                                )
                                .padding(.horizontal, Collo.Space.s2)
                                .frame(height: 26)
                                .background(
                                    record.isGranted ? Collo.Color.blue100 : Collo.Color.gray200,
                                    in: RoundedRectangle(cornerRadius: Collo.Radius.badgeMedium)
                                )
                        }
                        if let date = record.agreedAtDate {
                            Text("동의일: \(date.formatted(date: .long, time: .omitted))")
                                .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                        }
                        Text("문서 버전 \(record.documentVersion)")
                            .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Collo.Space.s4)
                    .background(
                        Collo.Color.gray100,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall)
                    )
                } else {
                    Text("아직 동의 기록이 없어요")
                        .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                }

                infoBlock(
                    "수집·이용 목적",
                    [
                        "통화 중 음성 신호(기침, 발화 속도, 휴지 비율, 기본주파수 변동)와 대화 내용을 분석해 개인 기준선 대비 변화 추이를 리포트로 제공합니다.",
                        "원본 오디오는 분석 즉시 폐기되며 장기 보관되지 않습니다.",
                        "분석 결과는 질환 판정이나 의료 진단에 사용되지 않습니다.",
                    ]
                )

                infoBlock(
                    "처리 원칙",
                    [
                        "수집 항목: 음향 지표, 건강 대화 구조화 결과",
                        "보유 기간: 동의 철회 시까지",
                        "공유 범위: 초대된 가족 구성원(열람 권한 범위 내)",
                    ]
                )

                infoBlock(
                    "동의 철회 안내",
                    [
                        "동의를 철회하면 통화 분석 및 리포트 생성 기능이 즉시 비활성화됩니다. 기존에 생성된 리포트와 타임라인은 보관 기간 내에 삭제 요청이 가능합니다.",
                    ]
                )

                // 서버 동의 이력은 append-only라 앱에서 수정하지 않는다. 철회 endpoint는
                // implementation-plan-v2 Phase 1에서 추가한다.
                Text("동의 철회는 아직 앱에서 처리할 수 없어요. 서버 철회 API가 준비되면 열려요.")
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray600, size: 12)

                if let errorMessage {
                    Text(errorMessage).colloText(Collo.Font.body02_300, .red, size: 14)
                }
            }
            .padding(Collo.Space.screen)
        }
        .navigationTitle("동의 관리")
        .navigationBarTitleDisplayMode(.inline)
        .background(Collo.Color.gray00)
        .task {
            defer { isLoading = false }
            do { record = try await CollogAPI.myConsent() } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func infoBlock(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Collo.Space.s2) {
            Text(title)
                .colloText(Collo.Font.body01_100, Collo.Color.gray900, size: 16)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .colloText(Collo.Font.caption01_200, Collo.Color.gray800, size: 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Collo.Space.s4)
        .background(Collo.Color.gray100, in: RoundedRectangle(cornerRadius: Collo.Radius.xsmall))
    }
}
