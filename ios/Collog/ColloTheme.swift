import SwiftUI

// 피그마 `일하자` 페이지(88:516)의 Foundation/Typography 토큰을 그대로 옮긴다.
// 값을 바꿀 때는 화면 코드가 아니라 이 파일만 고친다.
enum Collo {

    // MARK: - 색 (Foundation)

    enum Color {
        // Foundation/Orange
        static let orange = SwiftUI.Color(hex: 0xFF9400)
        static let orangeLight = SwiftUI.Color(hex: 0xFFF4E6)
        static let orangeLightHover = SwiftUI.Color(hex: 0xFFEFD9)
        static let orangeLightActive = SwiftUI.Color(hex: 0xFFDEB0)

        // Blue / Green
        static let blue100 = SwiftUI.Color(hex: 0xE5F3FF)
        static let blue600 = SwiftUI.Color(hex: 0x007AE6)
        static let green = SwiftUI.Color(hex: 0x26CF85)      // Green/Normal
        static let greenDark = SwiftUI.Color(hex: 0x1D9B64)  // Green/Dark

        /// 전화 목록 아바타 그라데이션의 밝은 쪽 (145:5411).
        static let avatarGradientStart = SwiftUI.Color(hex: 0xFFFBBF)

        // Gray 스케일
        static let gray00 = SwiftUI.Color.white
        static let gray100 = SwiftUI.Color(hex: 0xF7F8F9)
        static let gray200 = SwiftUI.Color(hex: 0xF3F4F5)
        static let gray300 = SwiftUI.Color(hex: 0xEEEFF1)
        static let gray600 = SwiftUI.Color(hex: 0xB0B3BA)
        static let gray700 = SwiftUI.Color(hex: 0x868B94)
        static let gray800 = SwiftUI.Color(hex: 0x555D6D)
        static let gray900 = SwiftUI.Color(hex: 0x2A3038)
        static let gray1000 = SwiftUI.Color(hex: 0x1A1C20)

        // Avatar (I145:5405;0:7331)
        static let avatarFill = SwiftUI.Color(hex: 0xFEF8F0)
        static let avatarStroke = green
    }

    // MARK: - 그라데이션

    enum Gradients {
        /// 전화 목록 아바타 (145:5411).
        /// `linear-gradient(234.81deg, #FFFBBF 34.75%, #26CF85 97.02%)`를 옮긴 것이다.
        /// CSS 각도는 위쪽이 0도이고 시계 방향으로 돈다. 234.81도는 좌하향이라
        /// 시작점을 그 반대편인 우상단에 둔다.
        static let avatar = LinearGradient(
            stops: [
                .init(color: Color.avatarGradientStart, location: 0.347),
                .init(color: Color.green, location: 0.970),
            ],
            startPoint: UnitPoint(x: 0.909, y: 0.212),
            endPoint: UnitPoint(x: 0.091, y: 0.788)
        )
    }

    // MARK: - 타이포그래피
    //
    // 피그마는 Pretendard/Inter를 쓰지만 두 폰트 파일은 저장소에 없다. 폰트를 임의로
    // 번들에 넣지 않고 크기·굵기·자간만 SF Pro로 맞춘다. 실제 폰트를 넣게 되면
    // 이 함수들의 `.system(...)`만 `.custom(...)`으로 바꾸면 된다.
    enum Font {
        static let headline02_100 = SwiftUI.Font.system(size: 24, weight: .bold)   // Pretendard Bold 24
        static let subtitle01_100 = SwiftUI.Font.system(size: 20, weight: .semibold) // Inter SemiBold 20
        static let body01_100 = SwiftUI.Font.system(size: 16, weight: .semibold)  // Inter SemiBold 16
        static let body01_200 = SwiftUI.Font.system(size: 16, weight: .medium)    // Pretendard Medium 16
        static let body02_100 = SwiftUI.Font.system(size: 14, weight: .semibold)  // Inter SemiBold 14
        static let body02_200 = SwiftUI.Font.system(size: 14, weight: .medium)    // Pretendard Medium 14
        static let body02_300 = SwiftUI.Font.system(size: 14, weight: .regular)   // Inter Regular 14
        static let caption01_100 = SwiftUI.Font.system(size: 12, weight: .semibold) // Inter SemiBold 12
        static let caption01_200 = SwiftUI.Font.system(size: 12, weight: .medium) // Pretendard Medium 12
        static let caption02_300 = SwiftUI.Font.system(size: 10, weight: .regular) // Inter Regular 10
    }

    // 피그마 전 텍스트 스타일의 letterSpacing은 -1%다.
    static func tracking(_ size: CGFloat) -> CGFloat { -size / 100 }

    // MARK: - 모서리 반경 (btn/*, badge/*)

    enum Radius {
        static let xsmall: CGFloat = 12
        static let small: CGFloat = 16
        static let medium: CGFloat = 20
        static let large: CGFloat = 26
        static let badgeMedium: CGFloat = 6
    }

    // MARK: - 간격 (spacing/*)

    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let screen: CGFloat = 24   // Body 좌우 padding
    }
}

extension View {
    // 피그마 텍스트 스타일 한 벌(폰트+색+자간+행간 1.45)을 한 번에 적용한다.
    func colloText(_ font: SwiftUI.Font, _ color: SwiftUI.Color, size: CGFloat) -> some View {
        self.font(font)
            .foregroundStyle(color)
            .tracking(Collo.tracking(size))
            .lineSpacing(size * 0.45)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
