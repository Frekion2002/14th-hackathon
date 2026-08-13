import SwiftUI

// 개발 빌드 로그인. 서버가 개발 환경에서 고정 OTP를 발급한다.
struct LoginView: View {
    @ObservedObject private var session = AppSession.shared

    @State private var phone = ""
    @State private var name = ""
    @State private var role = "CHILD"
    @State private var code = ""
    @State private var otpSent = false

    var body: some View {
        Form {
            Section("역할") {
                Picker("역할", selection: $role) {
                    Text("자녀").tag("CHILD")
                    Text("부모").tag("PARENT")
                }
                .pickerStyle(.segmented)
                .disabled(otpSent)
            }

            Section("계정") {
                TextField("이름", text: $name)
                    .textContentType(.name)
                TextField("전화번호", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .disabled(otpSent)
            }

            if otpSent {
                Section("인증번호") {
                    TextField("6자리", text: $code)
                        .keyboardType(.numberPad)
                    Text("개발 환경 기본값은 000000이다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(otpSent ? "확인하고 시작" : "인증번호 받기") {
                    Task { await submit() }
                }
                .disabled(session.isWorking || !isValid)

                if otpSent {
                    Button("전화번호 다시 입력", role: .cancel) {
                        otpSent = false
                        code = ""
                    }
                }
            }

            Section("서버 주소") {
                TextField("http://192.168.0.10:8080", text: backendBinding)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("실기기는 localhost로 개발 PC에 닿지 못한다. 같은 Wi-Fi의 LAN IP를 넣는다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let message = session.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("콜록 로그인")
    }

    private var isValid: Bool {
        if otpSent { return code.count == 6 }
        return phone.count >= 8 && !name.isEmpty
    }

    private var backendBinding: Binding<String> {
        Binding(
            get: { session.backendBaseURL },
            set: { session.backendBaseURL = $0 }
        )
    }

    private func submit() async {
        if otpSent {
            _ = await session.verifyOtp(phone: phone, code: code)
        } else if await session.requestOtp(phone: phone, role: role, name: name) {
            otpSent = true
        }
    }
}
