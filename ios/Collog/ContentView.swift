//
//  ContentView.swift
//  Collog
//
//  Created by 심재현 on 8/13/26.
//

import SwiftUI

// 앱 진입 흐름: 온보딩(첫 실행만) → 로그인 → 동의 → 홈 5탭.
//
// 동의는 앱 최초 온보딩의 완료 조건이다. 동의가 없거나 철회되면 홈/통화에 들여보내지 않고
// 동의 화면으로 돌린다. (HANDOFF 1절, implementation-plan-v2「인증·초대·동의」)
struct ContentView: View {
    @ObservedObject private var session = AppSession.shared
    @ObservedObject private var callCenter = VoipCallCenter.shared

    @AppStorage("collog.onboardingDone") private var onboardingDone = false
    @State private var consentState: ConsentState = .unknown

    enum ConsentState {
        case unknown
        case granted
        case missing
        /// 자녀 계정처럼 동의 주체가 아닌 경우. 동의 화면으로 보내지 않는다.
        case notRequired
    }

    var body: some View {
        Group {
            if !onboardingDone {
                OnboardingView()
            } else if !session.isLoggedIn {
                NavigationStack { LoginView() }
            } else {
                switch consentState {
                case .unknown:
                    ProgressView("확인 중…")
                case .missing:
                    NavigationStack {
                        ConsentView { consentState = .granted }
                    }
                case .granted, .notRequired:
                    RootTabView()
                }
            }
        }
        // 통화가 시작되면 어느 화면에 있든 통화 화면을 덮어씌운다.
        .fullScreenCover(item: callBinding) { call in
            CallView(initialCall: call)
        }
        .task(id: session.user?.id) { await refreshConsent() }
    }

    private func refreshConsent() async {
        guard session.isLoggedIn else {
            consentState = .unknown
            return
        }
        // 동의는 건강정보 당사자인 부모의 것이다. 서버도 `POST /v1/consents`를 PARENT로만
        // 받으므로(api.py `submit_consent`), 자녀를 이 게이트에 세우면 동의 화면에서
        // 403을 받고 영영 못 넘어간다.
        guard session.user?.role == "PARENT" else {
            consentState = .notRequired
            return
        }
        do {
            let record = try await CollogAPI.myConsent()
            consentState = (record?.isGranted == true) ? .granted : .missing
        } catch {
            // 서버에 닿지 못하면 동의 여부를 단정하지 않는다. 화면을 막기보다 동의로
            // 보내서 사용자가 다시 시도할 수 있게 한다.
            consentState = .missing
        }
    }

    private var callBinding: Binding<ActiveCall?> {
        Binding(get: { callCenter.activeCall }, set: { _ in })
    }
}

#Preview {
    ContentView()
}
