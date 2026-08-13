import AVFoundation
import LiveKit

// 별도의 AVAudioEngine input tap을 만들지 않고, LiveKit이 실제로 송출하는 것과 같은 캡처
// 스트림을 관찰해 분석용 PCM을 남긴다. 따라서 이 파일의 "원시 마이크"는 하드웨어 처리 전
// 원본이 아니라 AEC=true, AGC/NS=false 조건이 적용된 분석용 PCM이다.
//
// 서버 음향 분석기는 mono 48 kHz signed 16-bit little-endian PCM WAV만 받는다. float32
// WAV나 다른 sample rate를 그대로 올리면 INVALID_AUDIO로 거부된다.
final class AnalysisPCMWriter: NSObject, AudioRenderer, @unchecked Sendable {
    static let sampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "collog.analysis-pcm")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: AnalysisPCMWriter.sampleRate,
        channels: 1,
        interleaved: true
    )!

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var frameCount: AVAudioFramePosition = 0

    // 서버 음향 분석기가 -45 dBFS 이하를 SIGNAL_TOO_QUIET으로 거부한다. 기기에서 실제로
    // 어떤 레벨이 기록됐는지 남겨, 마이크가 조용한 것인지 변환이 잘못된 것인지 구분한다.
    private var peakSample: Int32 = 0
    private var squareSum: Double = 0
    private var sampleCount: Double = 0
    private var loggedSourceFormat = false

    // 서버 품질 게이트는 50ms 프레임 RMS의 분위수를 "활성 레벨"로 본다. 같은 통계를 기기에서
    // 그대로 계산해, 게이트 임계값을 추측이 아니라 실측으로 정할 수 있게 한다.
    private static let frameDurationSeconds = 0.05
    private var frameRMS: [Double] = []
    private var frameSquareSum: Double = 0
    private var frameSamples: Int = 0

    private(set) var url: URL?

    var durationSeconds: Double {
        queue.sync { Double(frameCount) / AnalysisPCMWriter.sampleRate }
    }

    struct LevelSummary {
        let peak: Double
        let rms: Double
        // 서버 게이트가 보는 값. 현재 기본 분위수는 90이다.
        let p75: Double
        let p90: Double
        let frames: Int
    }

    var levelSummary: LevelSummary {
        queue.sync {
            let peak = Double(peakSample) / Double(Int16.max)
            let rms = sampleCount > 0 ? (squareSum / sampleCount).squareRoot() : 0
            let sorted = frameRMS.sorted()
            return LevelSummary(
                peak: Self.decibels(peak),
                rms: Self.decibels(rms),
                p75: Self.decibels(Self.percentile(sorted, 0.75)),
                p90: Self.decibels(Self.percentile(sorted, 0.90)),
                frames: sorted.count
            )
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func decibels(_ amplitude: Double) -> Double {
        20 * log10(max(amplitude, 1e-9))
    }

    func start() throws {
        try queue.sync {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "collog-analysis", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: "\(UUID().uuidString).wav")
            // AVAudioFile은 settings의 sample rate/채널로 WAV 헤더를 쓴다.
            file = try AVAudioFile(
                forWriting: target,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            url = target
            frameCount = 0
        }
    }

    // LiveKit은 buffer를 재사용할 수 있으므로 callback 안에서 변환까지 끝내고 반환한다.
    func render(pcmBuffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let file = self.file else { return }
            do {
                if !self.loggedSourceFormat {
                    self.loggedSourceFormat = true
                    let format = pcmBuffer.format
                    print(
                        "[Collog] 캡처 포맷: \(format.sampleRate)Hz "
                            + "ch=\(format.channelCount) common=\(format.commonFormat.rawValue)"
                    )
                }
                let converted = try self.convert(pcmBuffer)
                try file.write(from: converted)
                self.frameCount += AVAudioFramePosition(converted.frameLength)
                self.accumulateLevels(converted)
            } catch {
                print("[Collog] 분석 PCM 기록 실패: \(error.localizedDescription)")
            }
        }
    }

    // renderer를 먼저 떼어낸 뒤 호출한다.
    func finish() -> URL? {
        queue.sync {
            file = nil
            converter = nil
            sourceFormat = nil
            return url
        }
    }

    func discard() {
        queue.sync {
            file = nil
            converter = nil
            sourceFormat = nil
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            url = nil
            frameCount = 0
        }
    }

    private func accumulateLevels(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData?.pointee else { return }
        for index in 0..<Int(buffer.frameLength) {
            let value = Int32(channel[index])
            peakSample = max(peakSample, abs(value))
            let normalized = Double(value) / Double(Int16.max)
            squareSum += normalized * normalized
            sampleCount += 1

            frameSquareSum += normalized * normalized
            frameSamples += 1
            if frameSamples >= frameLength {
                frameRMS.append((frameSquareSum / Double(frameSamples)).squareRoot())
                frameSquareSum = 0
                frameSamples = 0
            }
        }
    }

    private var frameLength: Int {
        Int(Self.frameDurationSeconds * Self.sampleRate)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == targetFormat {
            return buffer
        }
        if sourceFormat != buffer.format {
            guard let created = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                throw ConversionError.unsupportedFormat
            }
            converter = created
            sourceFormat = buffer.format
        }
        guard let converter else { throw ConversionError.unsupportedFormat }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw ConversionError.allocationFailed
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }

    enum ConversionError: LocalizedError {
        case unsupportedFormat
        case allocationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "분석용 PCM 변환 형식을 만들 수 없습니다"
            case .allocationFailed: return "분석용 PCM 버퍼를 만들 수 없습니다"
            }
        }
    }
}
