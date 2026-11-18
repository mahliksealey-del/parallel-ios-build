import Foundation

public struct StereoPCMBuffer: Equatable, Sendable {
    public var left: [Float]
    public var right: [Float]

    public init(frameCount: Int) {
        precondition(frameCount >= 0)
        left = Array(repeating: 0, count: frameCount)
        right = Array(repeating: 0, count: frameCount)
    }

    public var frameCount: Int { left.count }

    public var interleaved: [Float] {
        var result = Array(repeating: Float.zero, count: frameCount * 2)
        for frame in 0..<frameCount {
            result[2 * frame] = left[frame]
            result[2 * frame + 1] = right[frame]
        }
        return result
    }
}

public struct RendererPhaseSnapshot: Equatable, Sendable {
    public let left: Double
    public let right: Double

    public init(left: Double, right: Double) {
        self.left = left
        self.right = right
    }
}

private struct LinearFrequencyRamp: Sendable {
    var current: Double
    private var target: Double
    private var step: Double = 0
    private var remaining: Int = 0

    init(_ value: Double) {
        current = value
        target = value
    }

    mutating func setTarget(_ value: Double, frames: Int) {
        precondition(frames >= 0)
        if frames == 0 {
            current = value
            target = value
            step = 0
            remaining = 0
        } else {
            target = value
            step = (value - current) / Double(frames)
            remaining = frames
        }
    }

    mutating func advance() {
        guard remaining > 0 else { return }
        current += step
        remaining -= 1
        if remaining == 0 { current = target }
    }
}

private struct RaisedCosineGainRamp: Sendable {
    var current: Double
    private var start: Double
    private var target: Double
    private var total: Int = 0
    private var completed: Int = 0

    init(_ value: Double) {
        current = value
        start = value
        target = value
    }

    mutating func setTarget(_ value: Double, frames: Int) {
        precondition(frames >= 0)
        if frames == 0 {
            current = value
            start = value
            target = value
            total = 0
            completed = 0
        } else {
            start = current
            target = value
            total = frames
            completed = 0
        }
    }

    mutating func advance() {
        guard total > 0 else { return }
        completed += 1
        let fraction = min(1, Double(completed) / Double(total))
        let shaped = 0.5 - 0.5 * cos(.pi * fraction)
        current = start + (target - start) * shaped
        if completed == total {
            current = target
            total = 0
            completed = 0
        }
    }
}

/// Original, dependency-free stereo oscillator for offline parity research.
///
/// Phase is the angle of the next sample. Parameter updates never reset it.
/// The type owns no AVAudioSession, AVAudioEngine, SwiftUI, locks, or I/O.
public struct StereoPCMRenderer: Sendable {
    public let sampleRate: Double

    private var leftFrequency: LinearFrequencyRamp
    private var rightFrequency: LinearFrequencyRamp
    private var gain: RaisedCosineGainRamp
    private var leftPhase: Double
    private var rightPhase: Double

    public init(
        sampleRate: Double,
        leftFrequency: Double,
        rightFrequency: Double,
        gain: Double,
        initialPhase: RendererPhaseSnapshot = .init(left: 0, right: 0)
    ) {
        precondition(sampleRate > 0)
        Self.validateFrequency(leftFrequency, sampleRate: sampleRate)
        Self.validateFrequency(rightFrequency, sampleRate: sampleRate)
        Self.validateGain(gain)
        self.sampleRate = sampleRate
        self.leftFrequency = LinearFrequencyRamp(leftFrequency)
        self.rightFrequency = LinearFrequencyRamp(rightFrequency)
        self.gain = RaisedCosineGainRamp(gain)
        self.leftPhase = Self.wrap(initialPhase.left)
        self.rightPhase = Self.wrap(initialPhase.right)
    }

    public var phaseSnapshot: RendererPhaseSnapshot {
        .init(left: leftPhase, right: rightPhase)
    }

    public var currentFrequencies: (left: Double, right: Double) {
        (leftFrequency.current, rightFrequency.current)
    }

    public var currentGain: Double { gain.current }

    public mutating func setFrequencies(
        left: Double,
        right: Double,
        transitionFrames: Int = 0
    ) {
        Self.validateFrequency(left, sampleRate: sampleRate)
        Self.validateFrequency(right, sampleRate: sampleRate)
        leftFrequency.setTarget(left, frames: transitionFrames)
        rightFrequency.setTarget(right, frames: transitionFrames)
    }

    public mutating func setGain(_ value: Double, fadeFrames: Int = 0) {
        Self.validateGain(value)
        gain.setTarget(value, frames: fadeFrames)
    }

    /// Offline convenience method. Allocates left/right arrays.
    /// Do not invoke this method from an AVAudioSourceNode render callback.
    public mutating func render(frameCount: Int) -> StereoPCMBuffer {
        precondition(frameCount >= 0)
        var output = StereoPCMBuffer(frameCount: frameCount)
        output.left.withUnsafeMutableBufferPointer { left in
            output.right.withUnsafeMutableBufferPointer { right in
                render(into: left, right: right)
            }
        }
        return output
    }

    /// Caller-owned-buffer synthesis for a future real-time render adapter.
    /// No arrays, ARC objects, locks, I/O, or allocations are created explicitly
    /// by this method. The caller owns two independently writable buffers and
    /// guarantees that neither overlaps the other. This is not a full real-time
    /// allocation or thread-safety certification.
    public mutating func render(
        into left: UnsafeMutableBufferPointer<Float>,
        right: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(left.count == right.count)
        for frame in 0..<left.count {
            let amplitude = gain.current
            left[frame] = Float(amplitude * sin(leftPhase))
            right[frame] = Float(amplitude * sin(rightPhase))

            leftPhase = Self.wrap(
                leftPhase + 2 * .pi * leftFrequency.current / sampleRate
            )
            rightPhase = Self.wrap(
                rightPhase + 2 * .pi * rightFrequency.current / sampleRate
            )
            leftFrequency.advance()
            rightFrequency.advance()
            gain.advance()
        }
    }

    private static func validateFrequency(_ value: Double, sampleRate: Double) {
        precondition(value.isFinite && value >= 0 && value < sampleRate / 2)
    }

    private static func validateGain(_ value: Double) {
        precondition(value.isFinite && value >= 0 && value <= 1)
    }

    private static func wrap(_ phase: Double) -> Double {
        let period = 2 * Double.pi
        let remainder = phase.truncatingRemainder(dividingBy: period)
        return remainder >= 0 ? remainder : remainder + period
    }
}
