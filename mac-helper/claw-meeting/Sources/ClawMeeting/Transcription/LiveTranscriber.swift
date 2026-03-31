import AVFoundation
import FluidAudio
import Foundation

// MARK: - LiveTranscriber
//
// Wraps FluidAudio's SlidingWindowAsrManager (pseudo-streaming via overlapping windows).
//
// Real API used:
//   - SlidingWindowAsrManager (actor) — start(models:source:), streamAudio(_:), finish(), reset()
//   - SlidingWindowTranscriptionUpdate — text, isConfirmed, confidence, timestamp, tokenTimings
//   - AsrModels.downloadAndLoad() — downloads + loads Parakeet TDT CoreML models
//   - TokenTiming — token, startTime, endTime, confidence
//
// Note: FluidAudio's SlidingWindowAsrManager accepts AVAudioPCMBuffer, not raw [Float].
// The AudioMixer produces [Float] at 16 kHz mono, so we convert via LiveTranscriber.makePCMBuffer().
//
// Note: FluidAudio does NOT have a streaming transcriber that directly accepts [Float] samples
// with a per-sample callback. The SlidingWindowAsrManager is the closest thing: it buffers
// audio internally and emits SlidingWindowTranscriptionUpdate events as windows are processed.

final class LiveTranscriber: @unchecked Sendable {

    // MARK: - Public callback

    /// Fires whenever FluidAudio emits a transcription update (volatile or confirmed).
    var onSegment: ((TranscriptSegment) -> Void)?

    // MARK: - Private state

    private let meetingId: String
    private let manager: SlidingWindowAsrManager
    private var updateTask: Task<Void, Never>?

    // MARK: - Init

    init(meetingId: String, config: SlidingWindowAsrConfig = .default) {
        self.meetingId = meetingId
        self.manager = SlidingWindowAsrManager(config: config)
    }

    // MARK: - Lifecycle

    /// Download FluidAudio models (if needed) and start the sliding-window engine.
    /// Must be called before `processAudio(_:)`.
    func start() async throws {
        try await manager.start(source: .microphone)
        scheduleUpdateListener()
    }

    /// Feed 16 kHz mono Float samples into the transcriber.
    /// Call this each time the AudioMixer produces a new buffer.
    func processAudio(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let buffer = try Self.makePCMBuffer(from: samples)
        Task { await manager.streamAudio(buffer) }
    }

    /// Signal end of audio and return the complete final transcript text.
    @discardableResult
    func stop() async throws -> String {
        let final_ = try await manager.finish()
        updateTask?.cancel()
        return final_
    }

    // MARK: - Helpers

    /// Convert raw 16 kHz mono [Float] samples to an AVAudioPCMBuffer that
    /// SlidingWindowAsrManager.streamAudio(_:) accepts.
    static func makePCMBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        else {
            throw TranscriberError.audioFormatCreationFailed
        }

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            throw TranscriberError.audioBufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channelData.update(from: src.baseAddress!, count: samples.count)
            }
        }

        return buffer
    }

    // MARK: - Private

    /// Listen for transcription updates and map them to TranscriptSegment callbacks.
    private func scheduleUpdateListener() {
        updateTask?.cancel()
        let meetingId = self.meetingId
        let onSegment = self.onSegment
        let manager = self.manager

        updateTask = Task { [weak self] in
            guard let self else { return }
            for await update in await manager.transcriptionUpdates {
                guard !Task.isCancelled else { break }
                let segment = self.makeTranscriptSegment(from: update, meetingId: meetingId)
                onSegment?(segment)
            }
        }
    }

    private func makeTranscriptSegment(
        from update: SlidingWindowTranscriptionUpdate,
        meetingId: String
    ) -> TranscriptSegment {
        let words: [WordTiming] = update.tokenTimings.map { token in
            WordTiming(
                word: token.token,
                start: token.startTime,
                end: token.endTime
            )
        }

        return TranscriptSegment(
            meetingId: meetingId,
            timestamp: update.timestamp.timeIntervalSince1970,
            speaker: "unknown",  // Speaker assignment happens in DiarisationRunner post-meeting
            text: update.text,
            confidence: Double(update.confidence),
            words: words,
            isFinal: update.isConfirmed
        )
    }
}

// MARK: - Errors

enum TranscriberError: Error, LocalizedError {
    case audioFormatCreationFailed
    case audioBufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .audioFormatCreationFailed:
            return "Failed to create 16 kHz mono AVAudioFormat."
        case .audioBufferCreationFailed:
            return "Failed to allocate AVAudioPCMBuffer."
        }
    }
}
