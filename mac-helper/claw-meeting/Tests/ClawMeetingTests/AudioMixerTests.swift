import XCTest
import AVFoundation
@testable import ClawMeeting

final class AudioMixerTests: XCTestCase {
    func testRmsLevelOfSilence() {
        let silence = [Float](repeating: 0.0, count: 1000)
        let rms = AudioMixer.rmsLevel(silence)
        XCTAssertEqual(rms, 0.0, accuracy: 0.001)
    }

    func testRmsLevelOfSignal() {
        let signal = [Float](repeating: 0.5, count: 1000)
        let rms = AudioMixer.rmsLevel(signal)
        XCTAssertEqual(rms, 0.5, accuracy: 0.01)
    }

    func testRmsLevelOfEmptyBuffer() {
        let rms = AudioMixer.rmsLevel([])
        XCTAssertEqual(rms, 0.0)
    }

    func testOutputFormatIs16kHzMono() {
        let mixer = AudioMixer()
        XCTAssertEqual(mixer.outputFormat.sampleRate, 16000.0)
        XCTAssertEqual(mixer.outputFormat.channelCount, 1)
    }
}
