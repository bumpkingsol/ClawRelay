import FluidAudio
import Foundation

// MARK: - SpeakerSegment

/// A speaker-labelled time span from diarisation.
struct SpeakerSegment {
    let speaker: String
    let start: Double
    let end: Double
}

// MARK: - DiarisationRunner
//
// Wraps FluidAudio's OfflineDiarizerManager for post-meeting speaker diarisation.
//
// Real API used:
//   - OfflineDiarizerManager (final class, @available macOS 14.0+)
//     — prepareModels(), process(_ url:) -> DiarizationResult
//   - DiarizationResult — segments: [TimedSpeakerSegment]
//   - TimedSpeakerSegment — speakerId, startTimeSeconds, endTimeSeconds
//
// FluidAudio's offline diariser uses pyannote-style speaker embedding + VBx clustering.
// It returns per-speaker time intervals. We map each TimedSpeakerSegment to a SpeakerSegment
// and expose assignSpeakers() to enrich TranscriptSegments with speaker labels.
//
// Note: OfflineDiarizerManager is NOT an actor — it is a final class that manages its own
// internal concurrency. Methods can be called from async contexts directly.

@available(macOS 14.0, *)
final class DiarisationRunner: @unchecked Sendable {

    // MARK: - Private state

    private let manager: OfflineDiarizerManager

    // MARK: - Init

    init(config: OfflineDiarizerConfig = .default) {
        self.manager = OfflineDiarizerManager(config: config)
    }

    // MARK: - Model preparation

    /// Download + compile OfflineDiarizer models (if not already cached).
    /// Safe to call multiple times — skips download if already prepared.
    func prepare() async throws {
        try await manager.prepareModels()
    }

    // MARK: - Diarisation

    /// Run speaker diarisation on an audio file.
    ///
    /// - Parameter url: Path to audio file. Converted to 16 kHz mono internally.
    /// - Returns: Ordered array of SpeakerSegment, one per detected speech span.
    func diarise(url: URL) async throws -> [SpeakerSegment] {
        let result = try await manager.process(url)
        return result.segments.map { segment in
            SpeakerSegment(
                speaker: segment.speakerId,
                start: Double(segment.startTimeSeconds),
                end: Double(segment.endTimeSeconds)
            )
        }
    }

    // MARK: - Speaker assignment

    /// Merge diarisation speaker labels into an array of TranscriptSegment objects.
    ///
    /// For each transcript segment the algorithm finds the SpeakerSegment whose
    /// time span overlaps the most with the transcript's word timings. When no
    /// word timings are available the segment's `timestamp` field is used as a
    /// point lookup.
    ///
    /// - Parameters:
    ///   - segments: Transcript segments to enrich (typically from BatchTranscriber).
    ///   - speakers: Diarisation output from `diarise(url:)`.
    /// - Returns: New array of TranscriptSegment with speaker fields filled in.
    static func assignSpeakers(
        to segments: [TranscriptSegment],
        from speakers: [SpeakerSegment]
    ) -> [TranscriptSegment] {
        guard !speakers.isEmpty else { return segments }

        return segments.map { segment in
            let label = bestSpeaker(for: segment, in: speakers)
            return TranscriptSegment(
                meetingId: segment.meetingId,
                timestamp: segment.timestamp,
                speaker: label,
                text: segment.text,
                confidence: segment.confidence,
                words: segment.words,
                isFinal: segment.isFinal
            )
        }
    }

    // MARK: - Private helpers

    /// Returns the speaker label with the most overlap for the given segment.
    private static func bestSpeaker(
        for segment: TranscriptSegment,
        in speakers: [SpeakerSegment]
    ) -> String {
        // Derive a time range from word timings when available
        let segStart: Double
        let segEnd: Double

        if !segment.words.isEmpty,
            let firstWord = segment.words.first,
            let lastWord = segment.words.last
        {
            segStart = firstWord.start
            segEnd = lastWord.end
        } else {
            // Fall back to timestamp as a single point; treat it as a tiny span
            segStart = segment.timestamp
            segEnd = segment.timestamp + 0.001
        }

        // Pick the speaker whose span overlaps the most with [segStart, segEnd]
        var bestLabel = "unknown"
        var bestOverlap = 0.0

        for speakerSeg in speakers {
            let overlapStart = max(segStart, speakerSeg.start)
            let overlapEnd = min(segEnd, speakerSeg.end)
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestLabel = speakerSeg.speaker
            }
        }

        return bestLabel
    }
}
