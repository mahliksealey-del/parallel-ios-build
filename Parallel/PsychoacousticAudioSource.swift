import AVFoundation
import Foundation
import PsychoacousticDSP

/// Locks are used only on control/notification threads, never by the renderer.
/// Retains the control owner while a route notification disarms it.
final class PsychoacousticEmergencyRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: RealtimeControlOwner?

    func bind(_ next: RealtimeControlOwner?) {
        lock.lock()
        owner = next
        lock.unlock()
    }

    func disarmImmediately() {
        lock.lock()
        owner?.disarmImmediately()
        lock.unlock()
    }
}

enum PsychoacousticAudioError: LocalizedError {
    case headphonesRequired
    case unsupportedAudioFormat
    case memoryAllocation
    case invalidParameters
    case controlQueueFull
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .headphonesRequired:
            return "Connect stereo wired or Bluetooth headphones before starting binaural audio."
        case .unsupportedAudioFormat:
            return "The audio route does not support the required stereo PCM format."
        case .memoryAllocation:
            return "Could not allocate psychoacoustic audio controls."
        case .invalidParameters:
            return "Choose a carrier from 100–800 Hz, beat difference from 1–40 Hz, and volume from 0–25%."
        case .controlQueueFull:
            return "Audio controls are temporarily busy. Release the slider and try again."
        case .startFailed(let detail):
            return "The psychoacoustic audio engine could not start: \(detail)"
        }
    }
}

/// Exact output-port policy. Port names are not trusted as headphone evidence.
/// Mono Bluetooth HFP, loudspeaker, AirPlay, HDMI, and unknown routes fail closed.
enum PsychoacousticOutputPolicy {
    static func stereoHeadphonesAvailable(_ session: AVAudioSession = .sharedInstance()) -> Bool {
        guard session.outputNumberOfChannels >= 2 else { return false }
        return session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE:
                return true
            default:
                return false
            }
        }
    }
}

/// Exactly one AVAudioSourceNode render callback owns and mutates this stream.
/// The owner is kept strongly alive until the graph has stopped and detached.
private final class PsychoacousticRenderBox: @unchecked Sendable {
    private var stream: RealtimeControlledStereoStream
    private let owner: RealtimeControlOwner

    init(owner: RealtimeControlOwner, renderer: StereoPCMRenderer) {
        self.owner = owner
        stream = RealtimeControlledStereoStream(
            renderer: renderer,
            control: owner.makeRenderPort()
        )
    }

    func render(_ frameCount: AVAudioFrameCount,
                _ list: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let count = Int(frameCount)
        guard buffers.count == 2,
              buffers[0].mNumberChannels == 1,
              buffers[1].mNumberChannels == 1,
              let rawLeft = buffers[0].mData,
              let rawRight = buffers[1].mData,
              Int(buffers[0].mDataByteSize) >= count * MemoryLayout<Float>.size,
              Int(buffers[1].mDataByteSize) >= count * MemoryLayout<Float>.size else {
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
        let left = UnsafeMutableBufferPointer(
            start: rawLeft.assumingMemoryBound(to: Float.self),
            count: count
        )
        let right = UnsafeMutableBufferPointer(
            start: rawRight.assumingMemoryBound(to: Float.self),
            count: count
        )
        stream.render(into: left, right: right)
        return noErr
    }
}

struct PsychoacousticAudioNodes {
    let source: AVAudioSourceNode
    let gainMixer: AVAudioMixerNode
    let format: AVAudioFormat
    let owner: RealtimeControlOwner

    static func make(sampleRate: Double, leftHz: Double, rightHz: Double,
                     targetGain: Double) throws -> PsychoacousticAudioNodes {
        guard sampleRate.isFinite, sampleRate >= 8_000,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              !format.isInterleaved,
              format.commonFormat == .pcmFormatFloat32 else {
            throw PsychoacousticAudioError.unsupportedAudioFormat
        }
        guard let owner = RealtimeControlOwner(sampleRate: sampleRate) else {
            throw PsychoacousticAudioError.memoryAllocation
        }
        // The UI's valid ranges are deliberately well below Nyquist.
        guard leftHz.isFinite, rightHz.isFinite,
              leftHz >= 100, rightHz <= 840, rightHz > leftHz,
              rightHz < sampleRate / 2, targetGain.isFinite,
              (0...0.25).contains(targetGain) else {
            throw PsychoacousticAudioError.invalidParameters
        }

        let renderer = StereoPCMRenderer(
            sampleRate: sampleRate,
            leftFrequency: leftHz,
            rightFrequency: rightHz,
            gain: 0
        )
        // The actual AVAudioSession route was checked by the caller.
        owner.armAfterVerifiedStereoRoute()
        guard owner.sendGain(targetGain, fadeFrames: Int(sampleRate * 0.08)) else {
            owner.disarmImmediately()
            throw PsychoacousticAudioError.controlQueueFull
        }
        let box = PsychoacousticRenderBox(owner: owner, renderer: renderer)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            box.render(frameCount, bufferList)
        }
        let mixer = AVAudioMixerNode()
        mixer.outputVolume = 1
        return PsychoacousticAudioNodes(source: source, gainMixer: mixer,
                                        format: format, owner: owner)
    }

    @discardableResult
    func setFrequencies(left: Double, right: Double, transitionFrames: Int) -> Bool {
        owner.sendFrequencies(left: left, right: right, transitionFrames: transitionFrames)
    }

    @discardableResult
    func setGain(_ gain: Double, fadeFrames: Int) -> Bool {
        owner.sendGain(gain, fadeFrames: fadeFrames)
    }
}
