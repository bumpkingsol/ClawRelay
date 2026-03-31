import AVFoundation
import CoreAudio

@available(macOS 14.2, *)
final class SystemAudioCapture {
    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        // Create process tap (captures all system audio, stereo mixdown)
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .unmuted

        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapStatus == noErr else {
            throw AudioCaptureError.tapCreationFailed(tapStatus)
        }

        // Create aggregate device that routes the tap output
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "ClawMeeting System Tap",
            kAudioAggregateDeviceUIDKey as String: "com.openclaw.clawmeeting.systap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString]
            ],
        ]

        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioCaptureError.aggregateDeviceFailed(aggStatus)
        }

        // Install IO proc to receive captured audio buffers
        // Block signature: (inNow, inInputData, inInputTime, outOutputData, inOutputTime)
        // inInputData is UnsafePointer<AudioBufferList> (const AudioBufferList* in C)
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) {
            [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let firstBuffer = inInputData.pointee.mBuffers
            guard let data = firstBuffer.mData else { return }

            let frameCount = firstBuffer.mDataByteSize / 4  // 4 bytes per Float32
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            memcpy(pcmBuffer.floatChannelData![0], data, Int(firstBuffer.mDataByteSize))

            self.onBuffer?(pcmBuffer)
        }

        guard ioStatus == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw AudioCaptureError.tapCreationFailed(ioStatus)
        }

        AudioDeviceStart(aggregateDeviceID, ioProcID)
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { stop() }
}

enum AudioCaptureError: Error {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case engineStartFailed(Error)
}
