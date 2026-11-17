import AVFoundation
import Foundation

public enum MetronomeEngineState: Equatable {
    case stopped
    case starting
    case playing
    case interrupted
    case recovering
    case failed(String)
}

public enum MetronomeEngineError: LocalizedError, Equatable {
    case invalidBPM
    case invalidGain
    case alreadyRunning
    case invalidSampleRate
    case graphStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBPM: return "Tempo must be between 30 and 300 BPM."
        case .invalidGain: return "Gain must be between 0 and 1."
        case .alreadyRunning: return "Stop playback before changing tempo."
        case .invalidSampleRate: return "The active audio route has no valid sample rate."
        case .graphStartFailed(let message): return "The audio graph could not start: \(message)"
        }
    }
}

// The app-level graph owns AVAudioEngine. The metronome only supplies nodes.
public struct MetronomeAudioNodes {
    public let source: AVAudioSourceNode
    public let gainMixer: AVAudioMixerNode
    public let format: AVAudioFormat
}

@MainActor
public protocol MetronomeEngineProtocol: AnyObject {
    var state: MetronomeEngineState { get }
    var bpm: Double { get }
    var gain: Float { get }
    var onStateChange: ((MetronomeEngineState) -> Void)? { get set }
    func setBPM(_ bpm: Double) throws
    func setGain(_ gain: Float) throws
    func makeNodes(sampleRate: Double) throws -> MetronomeAudioNodes
    func markPlaying()
    func markFailed(_ message: String)
    func stop()
    func markInterrupted()
    func markRecovering()
}

@MainActor
public final class MetronomeEngine: MetronomeEngineProtocol {
    public private(set) var state: MetronomeEngineState = .stopped {
        didSet { onStateChange?(state) }
    }
    public private(set) var bpm = 120.0
    public private(set) var gain: Float = 0.65
    public var onStateChange: ((MetronomeEngineState) -> Void)?
    private var gainMixer: AVAudioMixerNode?

    public init() {}

    public func setBPM(_ bpm: Double) throws {
        guard state == .stopped || isFailure else { throw MetronomeEngineError.alreadyRunning }
        guard bpm.isFinite, BeatFrameScheduler.bpmRange.contains(bpm) else { throw MetronomeEngineError.invalidBPM }
        self.bpm = bpm
    }

    public func setGain(_ gain: Float) throws {
        guard gain.isFinite, (0...1).contains(gain) else { throw MetronomeEngineError.invalidGain }
        self.gain = gain
        gainMixer?.outputVolume = gain
    }

    public func makeNodes(sampleRate: Double) throws -> MetronomeAudioNodes {
        guard state != .playing && state != .starting else { throw MetronomeEngineError.alreadyRunning }
        guard sampleRate.isFinite, sampleRate > 0 else { throw MetronomeEngineError.invalidSampleRate }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw MetronomeEngineError.invalidSampleRate
        }
        state = .starting
        let mixer = AVAudioMixerNode()
        mixer.outputVolume = gain
        let renderState = RenderState(bpm: bpm, sampleRate: sampleRate)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            renderState.render(frameCount: frameCount, audioBufferList: audioBufferList)
            return noErr
        }
        gainMixer = mixer
        return MetronomeAudioNodes(source: source, gainMixer: mixer, format: format)
    }

    public func markPlaying() { state = .playing }
    public func markFailed(_ message: String) { gainMixer = nil; state = .failed(message) }
    public func stop() { gainMixer = nil; state = .stopped }
    public func markInterrupted() { gainMixer = nil; state = .interrupted }
    public func markRecovering() { gainMixer = nil; state = .recovering }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }


}

private final class RenderState: @unchecked Sendable {
    private let sampleRate: Double
    private let framesPerBeat: Double
    private var framePosition = 0.0
    private var nextBeatFrame = 0.0
    private var beatIndex = 0
    private var clickRemaining = 0
    private var clickLength = 0
    private var clickFrequency = 1_000.0

    init(bpm: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.framesPerBeat = sampleRate * 60.0 / bpm
    }

    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<Int(frameCount) {
            if framePosition + 0.5 >= nextBeatFrame {
                let accent = beatIndex == 0
                clickLength = max(1, Int(sampleRate * 0.018))
                clickRemaining = clickLength
                clickFrequency = accent ? 1_600.0 : 1_050.0
                beatIndex = (beatIndex + 1) % 4
                nextBeatFrame += framesPerBeat
            }
            var sample: Float = 0
            if clickRemaining > 0 {
                let elapsed = clickLength - clickRemaining
                let phase = 2.0 * Double.pi * clickFrequency * Double(elapsed) / sampleRate
                let envelope = Double(clickRemaining) / Double(clickLength)
                sample = Float(sin(phase) * envelope * envelope * 0.55)
                clickRemaining -= 1
            }
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
            }
            framePosition += 1
        }
    }
}
