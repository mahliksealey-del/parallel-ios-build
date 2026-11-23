import AVFoundation
import Foundation
import Darwin

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
    var boostedClicks: Bool { get }
    var clockSettings: ClockRhythmSettings { get }
    var onStateChange: ((MetronomeEngineState) -> Void)? { get set }
    func setBPM(_ bpm: Double) throws
    func setGain(_ gain: Float) throws
    func setBoostedClicks(_ enabled: Bool) throws
    func setClockSettings(_ settings: ClockRhythmSettings) throws
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
    /// Opt-in stronger click, using immutable per-render-state amplitude.
    /// Normal 0.55, boosted 0.90 (about +4.28 dB); below PCM full scale.
    public private(set) var boostedClicks = false
    public private(set) var clockSettings = ClockRhythmSettings()
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

    public func setBoostedClicks(_ enabled: Bool) throws {
        guard state == .stopped || isFailure else { throw MetronomeEngineError.alreadyRunning }
        boostedClicks = enabled
    }

    public func setClockSettings(_ settings: ClockRhythmSettings) throws {
        guard state == .stopped || isFailure else { throw MetronomeEngineError.alreadyRunning }
        guard settings.isValid else {
            throw MetronomeEngineError.graphStartFailed("Invalid clock rhythm settings.")
        }
        clockSettings = settings
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
        let renderState = RenderState(
            bpm: bpm, sampleRate: sampleRate,
            peakAmplitude: boostedClicks ? 0.90 : 0.55,
            settings: clockSettings,
            anchorWallSeconds: Date().timeIntervalSince1970,
            anchorHostSeconds: AVAudioTime.seconds(forHostTime: mach_absolute_time())
        )
        let source = AVAudioSourceNode(format: format) { _, timestamp, frameCount, audioBufferList -> OSStatus in
            renderState.render(
                timestamp: timestamp, frameCount: frameCount,
                audioBufferList: audioBufferList
            )
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

/// Each voice is finite, allocated before render, and advanced without locks.
/// Keep this small: no heap work, Date calls, network, UI, or buffer allocations
/// on the real-time audio thread.
private struct ClickVoice {
    private var samplesRemaining = 0
    private var durationSamples = 1
    private var phaseIncrement = 0.0
    private var phase = 0.0
    private var amplitude = 0.0

    mutating func start(frequency: Double, seconds: Double, volume: Double,
                        sampleRate: Double) {
        durationSamples = max(1, Int(seconds * sampleRate))
        samplesRemaining = durationSamples
        phaseIncrement = 2 * Double.pi * frequency / sampleRate
        phase = 0
        amplitude = volume
    }

    mutating func next() -> Double {
        guard samplesRemaining > 0 else { return 0 }
        let envelope = Double(samplesRemaining) / Double(durationSamples)
        let output = sin(phase) * envelope * envelope * amplitude
        phase += phaseIncrement
        samplesRemaining -= 1
        return output
    }
}

/// Longer, legato "GO" arrival cue on full clock/musical supercycle
/// coincidence. Intentionally unlike the short/high HH:MM:00 tick:
/// low G4 (392 Hz) with a gentle octave harmonic, 1.0 second total,
/// soft 30 ms onset and 250 ms release. No sample buffers/allocations.
private struct MasterSuccessVoice {
    private var frame = 0
    private var frameCount = 0
    private var attackFrames = 1
    private var releaseFrames = 1
    private var amplitude = 0.0
    private var phase = 0.0
    private var phaseStep = 0.0

    mutating func start(sampleRate: Double, volume: Double) {
        frame = 0
        frameCount = max(1, Int(sampleRate * 1.0))
        attackFrames = max(1, Int(sampleRate * 0.03))
        releaseFrames = max(1, Int(sampleRate * 0.25))
        amplitude = max(0, min(0.35, volume))
        phase = 0
        phaseStep = 2 * Double.pi * 392.0 / sampleRate
    }

    mutating func next() -> Double {
        guard frame < frameCount else { return 0 }
        let elapsed = frame
        let attack = min(1.0, Double(elapsed) / Double(attackFrames))
        let release = min(1.0, Double(frameCount - elapsed) / Double(releaseFrames))
        let envelope = min(attack, release)
        // The sustained fundamental + octave sounds like a musical "GO",
        // not another high-frequency clock tick.
        let tone = (sin(phase) + 0.24 * sin(2.0 * phase)) / 1.24
        phase += phaseStep
        frame += 1
        return amplitude * envelope * tone
    }
}

private final class RenderState: @unchecked Sendable {
    private let sampleRate: Double
    private let secondsPerNotePulse: Double
    private let secondsPerQuarter: Double
    private let secondsPerBreathCount: Double
    private let peakAmplitude: Double
    private let settings: ClockRhythmSettings
    private let anchorWallSeconds: Double
    private let anchorHostSeconds: Double
    private var lastBeatIndex: Int64?
    private var minuteLatch = ClockBoundaryLatch()
    private var lastBreathStartIndex: Int64?
    private var lastBreathOutIndex: Int64?
    private var lastCrossIndex: Int64?
    private var lastGroupIndex: Int64?
    private var legacyFramePosition = 0.0
    private var legacyNextBeatFrame = 0.0
    private var legacyBeatIndex = 0
    private var beatVoice = ClickVoice()
    private var minuteVoice = ClickVoice()
    private var masterVoice = MasterSuccessVoice()
    private var breathVoice = ClickVoice()
    private var crossVoice = ClickVoice()
    private var groupVoice = ClickVoice()
    private let fullAlignmentMinutes: Int64?

    init(bpm: Double, sampleRate: Double, peakAmplitude: Double,
         settings: ClockRhythmSettings, anchorWallSeconds: Double,
         anchorHostSeconds: Double) {
        self.sampleRate = sampleRate
        self.secondsPerQuarter = 60 / bpm
        self.secondsPerNotePulse = 60 / bpm * 4 / Double(settings.meterDenominator)
        self.secondsPerBreathCount = 60 / bpm * 4 / Double(settings.countDenominator)
        self.peakAmplitude = peakAmplitude
        self.settings = settings
        self.anchorWallSeconds = anchorWallSeconds
        self.anchorHostSeconds = anchorHostSeconds
        self.fullAlignmentMinutes = ClockRhythmMath.analyze(bpm: bpm, settings: settings)?
            .masterAlignmentMinutes
    }

    func render(timestamp: UnsafePointer<AudioTimeStamp>, frameCount: AVAudioFrameCount,
                audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        // Core Audio explicitly marks which timestamp fields are valid.
        // Nonzero mHostTime alone is not proof of a valid timestamp.
        let validHostTime = timestamp.pointee.mFlags.contains(.hostTimeValid)
            && timestamp.pointee.mHostTime > 0
        let startUnix: Double
        if settings.clockSync && validHostTime {
            // AVAudioSourceNode delivers the buffer's host timeline. Convert
            // the host timestamp ONCE per buffer, not in the sample loop.
            let hostSeconds = AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime)
            startUnix = anchorWallSeconds + (hostSeconds - anchorHostSeconds)
        } else {
            // Host time was not supplied for this audio callback. Use a
            // monotonic host reading (not a stale start-time sample counter)
            // so startup delays do not displace the entire clock grid.
            // This remains uncalibrated for hardware output buffering.
            let hostSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            startUnix = anchorWallSeconds + (hostSeconds - anchorHostSeconds)
        }
        for frame in 0..<Int(frameCount) {
            if settings.clockSync {
                let unix = startUnix + Double(frame) / sampleRate
                renderClockEvents(atUnixSeconds: unix)
            } else {
                // Exact original phase-zero behavior remains when Clock Sync
                // is disabled, including immediate first click.
                if legacyFramePosition + 0.5 >= legacyNextBeatFrame {
                    let accent = legacyBeatIndex == 0
                    beatVoice.start(
                        frequency: accent ? 1_600 : 1_050, seconds: 0.018,
                        volume: peakAmplitude, sampleRate: sampleRate
                    )
                    legacyBeatIndex = (legacyBeatIndex + 1) % settings.meterNumerator
                    legacyNextBeatFrame += sampleRate * secondsPerNotePulse
                }
                legacyFramePosition += 1
            }

            var sound = beatVoice.next()
            if settings.clockSync {
                sound += minuteVoice.next()
                sound += masterVoice.next()
                sound += breathVoice.next()
                sound += crossVoice.next()
                sound += groupVoice.next()
                // Single clicks preserve their intended loudness. An
                // identity-through-0.92 smooth limiter limits coincident
                // tones below full scale without re-amplifying quiet sound.
                let magnitude = abs(sound)
                if magnitude > 0.92 {
                    sound = (sound < 0 ? -1 : 1) *
                        (0.92 + 0.075 * tanh((magnitude - 0.92) / 0.075))
                }
            }
            let sample = Float(sound)
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
    }

    private func renderClockEvents(atUnixSeconds unix: Double) {
        guard let beat = ClockRhythmMath.eventIndex(atUnixSeconds: unix,
                                                  period: secondsPerNotePulse),
              let minute = ClockRhythmMath.eventIndex(atUnixSeconds: unix, period: 60)
        else { return }
        let minuteCrossed = minuteLatch.advance(to: minute)
        let sounds = ClockRhythmMath.boundarySounds(
            minuteIndex: minute, settings: settings,
            fullAlignmentMinutes: fullAlignmentMinutes)
        let masterBoundary = minuteCrossed && sounds.masterSuccess
        if let previous = lastBeatIndex, beat > previous {
            let accent = beat % Int64(settings.meterNumerator) == 0
            // The unique minute chime wins when musical and real-world
            // boundaries overlap. Do not stack two full-power transients.
            let beatGain: Double = (minuteCrossed && (sounds.ordinaryMinute || masterBoundary)) ? 0.25 : 1.0
            beatVoice.start(frequency: accent ? 1_600 : 1_050,
                            seconds: 0.018, volume: peakAmplitude * beatGain,
                            sampleRate: sampleRate)
        }
        lastBeatIndex = beat

        if minuteCrossed {
            // The minute signal is ALWAYS the same short recognizable tick.
            // Its identity must not be replaced by an alignment chime.
            if sounds.ordinaryMinute {
                let frequency: Double = settings.markerVariant == 0 ? 1_830 :
                    (settings.markerVariant == 1 ? 2_500 : 1_380)
                minuteVoice.start(frequency: frequency, seconds: 0.065,
                                  volume: peakAmplitude * settings.markerVolume,
                                  sampleRate: sampleRate)
            }
            // Independent low sustained "GO" cue, layered at safe gain
            // with the minute tick only when the master pattern realigns.
            if sounds.masterSuccess {
                masterVoice.start(
                    sampleRate: sampleRate,
                    volume: peakAmplitude * settings.groupCueVolume * 1.3
                )
            }
        }
        // Higher-timeframe marker may be anchored either to real-world
        // clock blocks or the particular session's Play instant.
        let groupOrigin = settings.blockAnchor == .session
            ? (settings.sessionStartUnixSeconds ?? anchorWallSeconds) : 0
        let groupSeconds = Double(settings.groupingMinutes) * 60
        if let group = ClockRhythmMath.eventIndex(
            atUnixSeconds: unix - groupOrigin, period: groupSeconds) {
            if settings.supercycleCues && !masterBoundary,
               let previous = lastGroupIndex, group > previous {
                groupVoice.start(
                    frequency: 580, seconds: 0.11,
                    volume: peakAmplitude * settings.groupCueVolume,
                    sampleRate: sampleRate
                )
            }
            lastGroupIndex = group
        }

        let breathPeriod = secondsPerBreathCount *
            Double(settings.inhaleCounts + settings.exhaleCounts)
        let inhalePeriod = secondsPerBreathCount * Double(settings.inhaleCounts)
        let breathTime = settings.resetBreathingOnMinute
            ? ClockRhythmMath.positiveRemainder(unix, 60) : unix
        if let start = ClockRhythmMath.eventIndex(atUnixSeconds: breathTime,
                                                 period: breathPeriod),
           let out = ClockRhythmMath.eventIndex(atUnixSeconds: breathTime - inhalePeriod,
                                               period: breathPeriod) {
            if settings.breathCues, let previous = lastBreathStartIndex, start > previous {
                breathVoice.start(frequency: 680, seconds: 0.05,
                                  volume: peakAmplitude * settings.breathCueVolume, sampleRate: sampleRate)
            } else if settings.breathCues, let previous = lastBreathOutIndex, out > previous {
                breathVoice.start(frequency: 420, seconds: 0.065,
                                  volume: peakAmplitude * settings.breathCueVolume * 0.9, sampleRate: sampleRate)
            }
            lastBreathStartIndex = start
            lastBreathOutIndex = out
        }

        let crossPeriod: Double?
        switch settings.crossMode {
        case .off: crossPeriod = nil
        case .grouped:
            crossPeriod = secondsPerQuarter * Double(settings.crossGroup)
        case .ratio:
            crossPeriod = secondsPerQuarter * Double(settings.ratioDuration) /
                Double(settings.ratioPulses)
        }
        if let crossPeriod,
           let cross = ClockRhythmMath.eventIndex(atUnixSeconds: unix, period: crossPeriod) {
            if let previous = lastCrossIndex, cross > previous {
                crossVoice.start(frequency: 780, seconds: 0.012,
                                 volume: peakAmplitude * settings.crossCueVolume, sampleRate: sampleRate)
            }
            lastCrossIndex = cross
        }
    }
}
