import FluidAudio
import Foundation

// MARK: - BatchTranscriber
//
// Wraps FluidAudio's AsrManager for high-quality post-meeting batch transcription.
//
// Real API used:
//   - AsrManager (actor) — initialize(models:), transcribe(_ url:source:), cleanup()
//   - AsrModels.downloadAndLoad() — downloads + loads Parakeet TDT v3 CoreML models
//   - ASRResult — text, confidence, duration, processingTime, tokenTimings
//   - TokenTiming — token, startTime, endTime, confidence
//
// The AsrManager resets decoder state after each transcribe() call, making it
// stateless and safe to reuse across multiple files.

final class BatchTranscriber: @unchecked Sendable {

    // MARK: - Private state

    private let manager: AsrManager

    // MARK: - Init

    init(config: ASRConfig = .default) {
        self.manager = AsrManager(config: config)
    }

    // MARK: - Transcription

    /// Load FluidAudio models (downloads from HuggingFace if needed).
    /// Call once before transcribing. Safe to call multiple times (idempotent
    /// if models are already cached).
    func prepare() async throws {
        let models = try await AsrModels.downloadAndLoad()
        try await manager.initialize(models: models)
    }

    /// Transcribe an audio file and return an array of TranscriptSegment.
    ///
    /// - Parameters:
    ///   - url: Path to audio file. Any AVFoundation-supported format is accepted.
    ///          The file will be resampled to 16 kHz mono internally.
    ///   - meetingId: Identifier stamped on every returned TranscriptSegment.
    ///   - source: Audio source label; use `.system` for recorded meeting audio.
    /// - Returns: Array with one TranscriptSegment for the whole file. Word-level
    ///            segments are provided via the `words` field when token timings are available.
    func transcribe(
        url: URL,
        meetingId: String,
        source: AudioSource = .system
    ) async throws -> [TranscriptSegment] {
        let result = try await manager.transcribe(url, source: source)
        return [makeTranscriptSegment(from: result, meetingId: meetingId)]
    }

    /// Release CoreML model resources.
    func cleanup() async {
        await manager.cleanup()
    }

    // MARK: - Helpers

    private func makeTranscriptSegment(
        from result: ASRResult,
        meetingId: String
    ) -> TranscriptSegment {
        let words: [WordTiming] = (result.tokenTimings ?? []).map { token in
            WordTiming(
                word: token.token,
                start: token.startTime,
                end: token.endTime
            )
        }

        return TranscriptSegment(
            meetingId: meetingId,
            timestamp: 0,  // File-level transcription; relative timing is in words
            speaker: "unknown",  // Assigned downstream by DiarisationRunner.assignSpeakers()
            text: result.text,
            confidence: Double(result.confidence),
            words: words,
            isFinal: true
        )
    }
}
