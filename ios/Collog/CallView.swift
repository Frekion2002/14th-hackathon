import SwiftUI

// 발신과 수신이 같은 화면을 쓴다. 오늘의 질문은 연결 대기 중 낭독되고 통화 중에는
// 참고용으로 계속 보인다.
struct CallView: View {
    let call: ActiveCall
    @ObservedObject private var callCenter = VoipCallCenter.shared

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(call.peerName)
                    .font(.largeTitle.bold())
                Text(call.statusText)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 48)

            if let notice = call.notice {
                Text(notice)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if !call.questions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("오늘의 질문")
                        .font(.headline)
                    ForEach(call.questions) { question in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "quote.opening")
                                .foregroundStyle(.tint)
                            Text(question.text)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }

            Spacer()

            Button {
                callCenter.endActiveCall()
            } label: {
                Label("통화 종료", systemImage: "phone.down.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }
}
