import SwiftUI

// 피그마 `첫 화면`(92:5410) + `온보딩 1~3장`(124:3574 / 124:3587 / 124:3613).
//
// 피그마의 이 화면들은 와이어프레임 단계다. 문구와 구조는 그대로 옮기고 시각 스타일만
// 완성된 홈 대시보드에서 뽑은 `ColloTheme`으로 통일했다.
// 피그마 dot은 3개인데 헤드라인은 4개라, 문구를 버리지 않고 4장으로 만들었다.
struct OnboardingView: View {
    @AppStorage("collog.onboardingDone") private var onboardingDone = false
    @State private var page = 0

    private let pages: [Page] = [
        Page(
            title: "통화 한 번이 건강 기록이 됩니다",
            body: """
            부모님과의 통화에서 개인 기준선 대비 변화를 차분하게 확인하세요.
            진단이 아닌, 우리 가족만의 기록입니다.
            """,
            checks: []
        ),
        Page(
            title: "개인별 건강 질문을 통해 건강을 관리할 수 있어요",
            body: "되묻는 빈도, 기침, 말의 흐름과 같은 신호를 분석하여 개인별 건강질문을 제공합니다.",
            checks: []
        ),
        Page(
            title: "통화 속 변화를 조용히 기록해요",
            body: """
            통화가 끝나면 목소리 리듬, 기침, 말의 흐름 같은 신호를 분석해요.
            진단이 아니라 지난 통화와 비교한 참고값으로만 사용해요.
            """,
            checks: [
                "원본 오디오는 분석 후 즉시 폐기돼요",
                "사전 동의한 부모님 통화에만 적용돼요",
                "의료 진단이나 위험 등급은 제공하지 않아요",
            ]
        ),
        Page(
            title: "가족의 건강 변화를 공유해요",
            body: "가족의 주간, 월간 건강 데이터와 건강 타임라인을 공유해서 가족 간 건강 이해도를 맞춰요",
            checks: []
        ),
    ]

    struct Page {
        let title: String
        let body: String
        let checks: [String]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    pageView(item).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            dots

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onboardingDone = true
                }
            } label: {
                Text(page < pages.count - 1 ? "다음" : "시작하기")
                    .colloText(Collo.Font.body01_100, Collo.Color.gray00, size: 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        Collo.Color.orange,
                        in: RoundedRectangle(cornerRadius: Collo.Radius.medium)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Collo.Space.screen)
            .padding(.bottom, Collo.Space.screen)

            Button("건너뛰기") { onboardingDone = true }
                .colloText(Collo.Font.body02_300, Collo.Color.gray600, size: 14)
                .padding(.bottom, Collo.Space.s4)
        }
        .background(Collo.Color.gray00)
    }

    private func pageView(_ item: Page) -> some View {
        VStack(spacing: 32) {
            Spacer(minLength: 0)

            // 피그마의 「선형 그래프 넣기」 placeholder 자리. 홈과 같은 캐릭터를 쓴다.
            Image("HomeCharacter")
                .resizable()
                .scaledToFit()
                .frame(height: 220)

            VStack(spacing: Collo.Space.s3) {
                Text(item.title)
                    .colloText(Collo.Font.subtitle01_100, Collo.Color.gray1000, size: 20)
                    .multilineTextAlignment(.center)
                Text(item.body)
                    .colloText(Collo.Font.body02_300, Collo.Color.gray700, size: 14)
                    .multilineTextAlignment(.center)
            }

            if !item.checks.isEmpty {
                VStack(alignment: .leading, spacing: Collo.Space.s2) {
                    ForEach(item.checks, id: \.self) { check in
                        HStack(spacing: Collo.Space.s2) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Collo.Color.green)
                            Text(check)
                                .colloText(Collo.Font.body02_300, Collo.Color.gray800, size: 14)
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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Collo.Space.screen)
    }

    private var dots: some View {
        HStack(spacing: Collo.Space.s2) {
            ForEach(0..<pages.count, id: \.self) { index in
                Circle()
                    .fill(index == page ? Collo.Color.orange : Collo.Color.gray300)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.bottom, Collo.Space.s4)
    }
}
