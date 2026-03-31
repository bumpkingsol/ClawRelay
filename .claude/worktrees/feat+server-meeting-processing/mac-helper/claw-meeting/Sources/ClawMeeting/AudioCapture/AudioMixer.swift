import AVFoundation
import Accelerate

final class AudioMixer {
    private let targetSampleRate: Double
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    let outputFormat: AVAudioFormat

    var onMixedBuffer: (([Float]) -> Void)?

    init(targetSampleRate: Double = Config.sampleRate) {
        self.targetSampleRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate, channels: 1
        )!
    }

    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let resampled = resample(buffer, using: &micConverter) else { return }
        onMixedBuffer?(Array(UnsafeBufferPointer(
            start: resampled.floatChannelData![0],
            count: Int(resampled.frameLength)
        )))
    }

    func processSystemBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let resampled = resample(buffer, using: &systemConverter) else { return }
        onMixedBuffer?(Array(UnsafeBufferPointer(
            start: resampled.floatChannelData![0],
            count: Int(resampled.frameLength)
        )))
    }

    private func resample(
        _ buffer: AVAudioPCMBuffer,
        using converter: inout AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outputFrameCount
              ) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        return error == nil ? outputBuffer : nil
    }

    static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
