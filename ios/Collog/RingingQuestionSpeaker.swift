import AVFoundation

// 연결 대기 중 오늘의 질문을 발신자에게만 읽어준다. 통화 상대에게 송출되지 않는다.
// 서버가 ElevenLabs 음성을 제공하면 서명 URL을 재생하고, 없으면 기기 로컬 합성을 쓴다.
@MainActor
final class RingingQuestionSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var onEvent: ((String) -> Void)?
    private var remoteStarted = false

    func speak(_ question: CollogAPI.Question, onEvent: @escaping (String) -> Void) {
        stop()
        self.onEvent = onEvent
        if question.usesRemoteTTS,
           let rawURL = question.ttsAssetUrl,
           let remoteURL = URL(string: rawURL) {
            onEvent("ElevenLabs 질문 음성 로딩")
            let item = AVPlayerItem(url: remoteURL)
            let player = AVPlayer(playerItem: item)
            self.player = player
            statusObservation = item.observe(\.status, options: [.initial, .new]) {
                [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.player?.currentItem === item else { return }
                    switch item.status {
                    case .readyToPlay:
                        guard !self.remoteStarted else { return }
                        self.remoteStarted = true
                        self.onEvent?("ElevenLabs 질문 음성 재생 시작")
                        self.player?.play()
                    case .failed:
                        self.playLocalFallback(question.text)
                    case .unknown:
                        break
                    @unknown default:
                        self.playLocalFallback(question.text)
                    }
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.onEvent?("ElevenLabs 질문 음성 재생 완료")
                    self?.cleanupRemotePlayer()
                }
            }
            return
        }

        onEvent("iOS 로컬 폴백 질문 음성 재생")
        speakLocal(question.text)
    }

    private func speakLocal(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    private func playLocalFallback(_ text: String) {
        cleanupRemotePlayer()
        onEvent?("ElevenLabs 질문 재생 실패 → iOS 로컬 음성")
        speakLocal(text)
    }

    private func cleanupRemotePlayer() {
        player?.pause()
        player = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        remoteStarted = false
    }

    // 부모가 수락하면 문장 중간이어도 즉시 멈춘다.
    func stop(reason: String? = nil) {
        let wasPlaying = player != nil || synthesizer.isSpeaking
        cleanupRemotePlayer()
        synthesizer.stopSpeaking(at: .immediate)
        if wasPlaying, let reason {
            onEvent?(reason)
        }
        onEvent = nil
    }
}
