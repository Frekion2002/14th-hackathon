//
//  ContentView.swift
//  Collog
//
//  Created by 심재현 on 8/13/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var session = AppSession.shared
    @ObservedObject private var callCenter = VoipCallCenter.shared

    var body: some View {
        NavigationStack {
            if session.isLoggedIn {
                HomeView()
            } else {
                LoginView()
            }
        }
        // 통화가 시작되면 어느 화면에 있든 통화 화면을 덮어씌운다.
        .fullScreenCover(item: callBinding) { call in
            CallView(initialCall: call)
        }
    }

    private var callBinding: Binding<ActiveCall?> {
        Binding(get: { callCenter.activeCall }, set: { _ in })
    }
}

struct HomeView: View {
    @ObservedObject private var session = AppSession.shared
    @ObservedObject private var callCenter = VoipCallCenter.shared

    var body: some View {
        List {
            if let user = session.user {
                Section("내 계정") {
                    LabeledContent("이름", value: user.name)
                    LabeledContent("역할", value: user.role == "CHILD" ? "자녀" : "부모")
                }
            }

            if session.user?.role == "CHILD" {
                Section("가족") {
                    if session.members.isEmpty {
                        Text("초대한 부모가 없다. 백엔드에서 초대를 먼저 만든다.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.members) { member in
                        MemberRow(member: member) {
                            guard let userId = member.userId else { return }
                            callCenter.startOutgoingCall(calleeId: userId, name: member.name)
                        }
                    }
                }
            } else {
                Section("수신 대기") {
                    Text("자녀가 전화를 걸면 잠금화면에 통화 화면이 뜬다.")
                        .foregroundStyle(.secondary)
                }
            }

            DeveloperSection(callCenter: callCenter)

            Section {
                Button("로그아웃", role: .destructive) { session.logout() }
            }
        }
        .navigationTitle("콜록")
        .refreshable { await session.refreshMembers() }
        .task { await session.refreshMembers() }
    }
}

private struct MemberRow: View {
    let member: CollogAPI.Member
    let onCall: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCall) {
                Image(systemName: "phone.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!member.isCallable)
        }
    }

    private var statusText: String {
        switch member.status {
        case "CONSENT_GRANTED": return "동의 완료"
        case "CONSENT_PENDING": return "동의 대기"
        case "CONSENT_DENIED": return "동의 거절"
        case "INVITED": return "초대됨"
        default: return member.status
        }
    }
}

// 실기기 디버깅용. APNs 검증에 필요한 토큰을 눈으로 확인한다.
private struct DeveloperSection: View {
    @ObservedObject var callCenter: VoipCallCenter

    var body: some View {
        Section("개발 정보") {
            TokenRow(title: "VoIP 토큰", token: callCenter.voipToken)
            TokenRow(title: "APNs 토큰", token: callCenter.apnsToken)
            DisclosureGroup("이벤트 로그") {
                ForEach(Array(callCenter.events.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.caption)
                }
            }
        }
    }
}

private struct TokenRow: View {
    let title: String
    let token: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            if let token {
                Text(token)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                Button("복사") { UIPasteboard.general.string = token }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("발급 대기 중").foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
