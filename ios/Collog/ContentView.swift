//
//  ContentView.swift
//  Collog
//
//  Created by 심재현 on 8/13/26.
//

import SwiftUI
import UIKit

// 개발용 화면이다. PushKit 토큰을 눈으로 확인하고 backend의 check_apns.py에 넣기 위해 있다.
struct ContentView: View {
    @StateObject private var callCenter = VoipCallCenter.shared

    var body: some View {
        NavigationStack {
            List {
                Section("VoIP 토큰 (PushKit)") {
                    TokenRow(token: callCenter.voipToken)
                }
                Section("APNs 토큰 (일반 알림)") {
                    TokenRow(token: callCenter.apnsToken)
                }
                Section("이벤트") {
                    if callCenter.events.isEmpty {
                        Text("아직 없음").foregroundStyle(.secondary)
                    }
                    ForEach(Array(callCenter.events.enumerated()), id: \.offset) { _, event in
                        Text(event).font(.callout)
                    }
                }
            }
            .navigationTitle("콜록 개발")
        }
    }
}

private struct TokenRow: View {
    let token: String?

    var body: some View {
        if let token {
            VStack(alignment: .leading, spacing: 8) {
                Text(token)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button("복사") {
                    UIPasteboard.general.string = token
                }
                .buttonStyle(.bordered)
            }
        } else {
            Text("발급 대기 중").foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
