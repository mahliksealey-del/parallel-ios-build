import Foundation

public enum P3ReferenceFixture: String, CaseIterable, Sendable {
    case c01, c02, c03, c04, c05, c06
}

public enum ReferenceFixtureRenderer {
    public static func render(
        _ fixture: P3ReferenceFixture,
        sampleRate: Double,
        duration: Double = 30
    ) -> StereoPCMBuffer {
        precondition(sampleRate > 0 && duration > 0)
        let frameCount = Int((sampleRate * duration).rounded())
        switch fixture {
        case .c01:
            return renderCarriers(200, 210, sampleRate, frameCount)
        case .c02:
            return renderCarriers(440, 448, sampleRate, frameCount)
        case .c03:
            return renderCarriers(200, 200, sampleRate, frameCount)
        case .c04:
            return renderMonauralBeat(sampleRate, frameCount)
        case .c05:
            return renderAmplitudeModulation(sampleRate, frameCount)
        case .c06:
            return renderContinuousSweep(sampleRate, frameCount, duration)
        }
    }

    private static func renderCarriers(
        _ left: Double,
        _ right: Double,
        _ sampleRate: Double,
        _ frameCount: Int
    ) -> StereoPCMBuffer {
        var renderer = StereoPCMRenderer(
            sampleRate: sampleRate,
            leftFrequency: left,
            rightFrequency: right,
            gain: 0.2
        )
        return renderer.render(frameCount: frameCount)
    }

    private static func renderMonauralBeat(
        _ sampleRate: Double,
        _ frameCount: Int
    ) -> StereoPCMBuffer {
        var output = StereoPCMBuffer(frameCount: frameCount)
        var phase200 = 0.0
        var phase210 = 0.0
        let step200 = 2 * Double.pi * 200 / sampleRate
        let step210 = 2 * Double.pi * 210 / sampleRate
        for frame in 0..<frameCount {
            let sample = Float(0.1 * sin(phase200) + 0.1 * sin(phase210))
            output.left[frame] = sample
            output.right[frame] = sample
            phase200 = wrap(phase200 + step200)
            phase210 = wrap(phase210 + step210)
        }
        return output
    }

    private static func renderAmplitudeModulation(
        _ sampleRate: Double,
        _ frameCount: Int
    ) -> StereoPCMBuffer {
        var output = StereoPCMBuffer(frameCount: frameCount)
        var carrierPhase = 0.0
        var modulationPhase = 0.0
        let carrierStep = 2 * Double.pi * 200 / sampleRate
        let modulationStep = 2 * Double.pi * 10 / sampleRate
        for frame in 0..<frameCount {
            let envelope = 0.5 + 0.4 * sin(modulationPhase)
            let sample = Float(0.2 * envelope * sin(carrierPhase))
            output.left[frame] = sample
            output.right[frame] = sample
            carrierPhase = wrap(carrierPhase + carrierStep)
            modulationPhase = wrap(modulationPhase + modulationStep)
        }
        return output
    }

    private static func renderContinuousSweep(
        _ sampleRate: Double,
        _ frameCount: Int,
        _ duration: Double
    ) -> StereoPCMBuffer {
        var output = StereoPCMBuffer(frameCount: frameCount)
        var leftPhase = 0.0
        var rightPhase = 0.0
        let fadeFrames = max(1, Int((0.5 * sampleRate).rounded()))
        for frame in 0..<frameCount {
            let trajectory = frameCount == 1 ? 0 : Double(frame) / Double(frameCount - 1)
            let leftFrequency = 200 + 40 * trajectory
            let rightFrequency = 210 + 42 * trajectory
            let edgeGain: Double
            if frame < fadeFrames {
                let fraction = Double(frame) / Double(fadeFrames)
                edgeGain = pow(sin(.pi * 0.5 * fraction), 2)
            } else if frame >= frameCount - fadeFrames {
                let fromEnd = Double(frameCount - 1 - frame) / Double(fadeFrames)
                edgeGain = pow(sin(.pi * 0.5 * max(0, fromEnd)), 2)
            } else {
                edgeGain = 1
            }
            output.left[frame] = Float(0.2 * edgeGain * sin(leftPhase))
            output.right[frame] = Float(0.2 * edgeGain * sin(rightPhase))
            leftPhase = wrap(leftPhase + 2 * .pi * leftFrequency / sampleRate)
            rightPhase = wrap(rightPhase + 2 * .pi * rightFrequency / sampleRate)
        }
        _ = duration // retained in the signature to make the 30-second specification explicit
        return output
    }

    private static func wrap(_ phase: Double) -> Double {
        phase.truncatingRemainder(dividingBy: 2 * .pi)
    }
}
