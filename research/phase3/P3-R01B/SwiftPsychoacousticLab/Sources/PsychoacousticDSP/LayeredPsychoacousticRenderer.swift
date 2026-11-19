import Foundation

public enum PsychoacousticMode: String, CaseIterable, Sendable {
    case binaural
    case monaural
    case isochronic
}

public struct NoiseLevels: Equatable, Sendable {
    public var white: Double
    public var pink: Double
    public var brown: Double

    public init(white: Double = 0, pink: Double = 0, brown: Double = 0) {
        precondition([white, pink, brown].allSatisfy { $0.isFinite && (0...1).contains($0) })
        self.white = white
        self.pink = pink
        self.brown = brown
    }
}

/// Deterministic, allocation-free layered renderer for offline tests and an
/// AVAudioSourceNode adapter. It owns all phase and noise-filter state.
public struct LayeredPsychoacousticRenderer: Sendable {
    public let sampleRate: Double
    public private(set) var mode: PsychoacousticMode
    private var carrierHz: Double
    private var beatHz: Double
    private var toneGain: Double
    private var carrierStep = 0.0
    private var beatStep = 0.0
    private var frequencyFramesRemaining = 0
    private var toneGainStep = 0.0
    private var toneGainFramesRemaining = 0
    private var noise: NoiseLevels
    private var leftPhase = 0.0
    private var rightPhase = 0.0
    private var modulationPhase = 0.0
    private var randomState: UInt64
    private var pinkState = 0.0
    private var brownState = 0.0

    public init(sampleRate: Double, mode: PsychoacousticMode, carrierHz: Double,
                beatHz: Double, toneGain: Double, noise: NoiseLevels = .init(),
                seed: UInt64 = 0x5041_5241_4C4C_454C) {
        precondition(sampleRate >= 8_000 && sampleRate.isFinite)
        precondition(carrierHz >= 20 && carrierHz + beatHz < sampleRate / 2)
        precondition(beatHz > 0 && beatHz.isFinite)
        precondition(toneGain.isFinite && (0...1).contains(toneGain))
        self.sampleRate = sampleRate
        self.mode = mode
        self.carrierHz = carrierHz
        self.beatHz = beatHz
        self.toneGain = toneGain
        self.noise = noise
        self.randomState = seed == 0 ? 1 : seed
    }

    public mutating func render(into left: UnsafeMutableBufferPointer<Float>,
                                right: UnsafeMutableBufferPointer<Float>) {
        precondition(left.count == right.count)
        for index in left.indices {
            let carrier = sin(leftPhase)
            let second = sin(rightPhase)
            let toneLeft: Double
            let toneRight: Double
            switch mode {
            case .binaural:
                toneLeft = carrier
                toneRight = second
            case .monaural:
                let mixed = 0.5 * (carrier + second)
                toneLeft = mixed
                toneRight = mixed
            case .isochronic:
                // Raised-cosine gating avoids the discontinuities of a square pulse.
                let gate = 0.5 - 0.5 * cos(modulationPhase)
                toneLeft = carrier * gate
                toneRight = toneLeft
            }

            let white = nextWhite()
            pinkState += 0.04 * (white - pinkState)
            brownState = max(-1, min(1, brownState + white * 0.02))
            let bed = noise.white * white + noise.pink * pinkState + noise.brown * brownState
            left[index] = Float(softLimit(toneGain * toneLeft + bed))
            right[index] = Float(softLimit(toneGain * toneRight + bed))

            leftPhase = wrap(leftPhase + 2 * .pi * carrierHz / sampleRate)
            rightPhase = wrap(rightPhase + 2 * .pi * (carrierHz + beatHz) / sampleRate)
            modulationPhase = wrap(modulationPhase + 2 * .pi * beatHz / sampleRate)
            if frequencyFramesRemaining > 0 {
                carrierHz += carrierStep
                beatHz += beatStep
                frequencyFramesRemaining -= 1
            }
            if toneGainFramesRemaining > 0 {
                toneGain += toneGainStep
                toneGainFramesRemaining -= 1
            }
        }
    }

    public mutating func setMode(_ next: PsychoacousticMode) { mode = next }

    public mutating func setNoiseLevels(_ next: NoiseLevels) { noise = next }

    public mutating func setFrequencies(carrierHz: Double, beatHz: Double,
                                        transitionFrames: Int = 0) {
        precondition(carrierHz >= 20 && carrierHz + beatHz < sampleRate / 2 && beatHz > 0)
        precondition(transitionFrames >= 0)
        if transitionFrames == 0 {
            self.carrierHz = carrierHz
            self.beatHz = beatHz
            frequencyFramesRemaining = 0
        } else {
            carrierStep = (carrierHz - self.carrierHz) / Double(transitionFrames)
            beatStep = (beatHz - self.beatHz) / Double(transitionFrames)
            frequencyFramesRemaining = transitionFrames
        }
    }

    public mutating func setToneGain(_ next: Double, fadeFrames: Int = 0) {
        precondition(next.isFinite && (0...1).contains(next))
        precondition(fadeFrames >= 0)
        if fadeFrames == 0 {
            toneGain = next
            toneGainFramesRemaining = 0
        } else {
            toneGainStep = (next - toneGain) / Double(fadeFrames)
            toneGainFramesRemaining = fadeFrames
        }
    }

    private mutating func nextWhite() -> Double {
        randomState ^= randomState << 13
        randomState ^= randomState >> 7
        randomState ^= randomState << 17
        return Double(Int64(bitPattern: randomState)) / Double(Int64.max)
    }

    private func softLimit(_ sample: Double) -> Double {
        // Rational limiter is bounded, continuous, and inexpensive.
        sample / (1 + abs(sample))
    }

    private func wrap(_ phase: Double) -> Double {
        phase.truncatingRemainder(dividingBy: 2 * .pi)
    }
}
