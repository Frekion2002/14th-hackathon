import AVFoundation

// 연결 대기 중 오늘의 질문을 발신자에게만 읽어준다. 통화 상대에게 송출되지 않는다.
// Deepgram Aura가 한국어를 지원하지 않아 서버 TTS 대신 기기 로컬 합성을 쓴다.
@MainActor
final class RingingQuestionSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    // 부모가 수락하면 문장 중간이어도 즉시 멈춘다.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
