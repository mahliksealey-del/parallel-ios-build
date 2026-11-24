import AVFoundation
import Foundation
import PsychoacousticDSP

/// Conservative per-channel digital headroom for the first gain experiment.
/// A 0.50 peak is -6.02 dBFS per synthesized sine before other audio mixes.
/// This is not an acoustic loudness or hearing-safety guarantee.
enum PsychoacousticGainPolicy {
    static let maximum: Double = 0.50
    static let defaultLevel: Double = 0.15
}

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
            return "Connect wired headphones, a Bluetooth audio device, or car audio. Select the output first, then start the psychoacoustic engine."
        case .unsupportedAudioFormat:
            return "The audio route does not support the required stereo PCM format."
        case .memoryAllocation:
            return "Could not allocate psychoacoustic audio controls."
        case .invalidParameters:
            return "Choose a carrier from 100–800 Hz, beat difference from 1–40 Hz, and PCM gain from 0–50%."
        case .controlQueueFull:
            return "Audio controls are temporarily busy. Release the slider and try again."
        case .startFailed(let detail):
            return "The psychoacoustic audio engine could not start: \(detail)"
        }
    }
}

/// The original safe policy required headphones and rejected cars/Bluetooth
/// speakers. Accept explicitly identified external audio devices while still
/// rejecting silent, unknown, and built-in speaker routes. Headphone removal
/// continues to disarm all playback through AudioSessionCoordinator.
/// Binaural *perception* requires channel separation at the ears: in cars or
/// mono HFP/LE routes the tone still plays, but beat perception is not assured.
enum PsychoacousticOutputPolicy {
    static func stereoHeadphonesAvailable(_ session: AVAudioSession = .sharedInstance()) -> Bool {
        guard session.outputNumberOfChannels >= 2 else { return false }
        return session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE:
                return true
            default: return false
            }
        }
    }

    static func supportedExternalOutput(_ session: AVAudioSession = .sharedInstance()) -> Bool {
        supportsExternalRoute(
            portTypes: session.currentRoute.outputs.map(\.portType),
            outputChannels: session.outputNumberOfChannels
        )
    }

    static func supportsExternalRoute(
        portTypes: [AVAudioSession.Port], outputChannels: Int
    ) -> Bool {
        guard outputChannels >= 1 else { return false }
        return portTypes.contains { port in
            switch port {
            case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio:
                return true
            default:
                return false
            }
        }
    }

    static func hasStereoSeparation(_ session: AVAudioSession = .sharedInstance()) -> Bool {
        stereoHeadphonesAvailable(session)
    }
}

/// Exactly one AVAudioSourceNode render callback owns and mutates this stream.
/// The owner is kept strongly alive until the graph has stopped and detached.
private final class PsychoacousticRenderBox: @unchecked Sendable {
    private var stream: RealtimeControlledLayeredStream
    private let owner: RealtimeControlOwner

    init(owner: RealtimeControlOwner, renderer: LayeredPsychoacousticRenderer) {
        self.owner = owner
        stream = RealtimeControlledLayeredStream(
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
                     targetGain: Double, mode: PsychoacousticMode,
                     noise: NoiseLevels) throws -> PsychoacousticAudioNodes {
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
              (0...PsychoacousticGainPolicy.maximum).contains(targetGain) else {
            throw PsychoacousticAudioError.invalidParameters
        }

        let renderer = LayeredPsychoacousticRenderer(
            sampleRate: sampleRate, mode: mode, carrierHz: leftHz,
            beatHz: rightHz - leftHz, toneGain: targetGain, noise: noise
        )
        // The actual AVAudioSession route was checked by the caller.
        owner.armAfterVerifiedStereoRoute()
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

    @discardableResult
    func setMode(_ mode: PsychoacousticMode) -> Bool { owner.sendMode(mode) }

    @discardableResult
    func setNoise(_ noise: NoiseLevels) -> Bool { owner.sendNoise(noise) }
}
