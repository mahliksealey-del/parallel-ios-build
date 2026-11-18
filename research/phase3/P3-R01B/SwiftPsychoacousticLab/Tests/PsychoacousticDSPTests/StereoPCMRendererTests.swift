import XCTest
@testable import PsychoacousticDSP

final class StereoPCMRendererTests: XCTestCase {
    private let sampleRates = [44_100.0, 48_000.0, 96_000.0]

    func testIndependentCarriersAtAllSampleRates() {
        for rate in sampleRates {
            var renderer = StereoPCMRenderer(
                sampleRate: rate,
                leftFrequency: 200,
                rightFrequency: 210,
                gain: 0.2
            )
            let buffer = renderer.render(frameCount: Int(rate * 2))
            XCTAssertEqual(estimateFrequency(buffer.left, sampleRate: rate), 200, accuracy: 0.2)
            XCTAssertEqual(estimateFrequency(buffer.right, sampleRate: rate), 210, accuracy: 0.2)
            XCTAssertEqual(rms(buffer.left), 0.2 / sqrt(2), accuracy: 0.000_02)
            XCTAssertEqual(rms(buffer.right), 0.2 / sqrt(2), accuracy: 0.000_02)
            XCTAssertLessThanOrEqual(peak(buffer), 0.200_01)
            XCTAssertTrue(buffer.left.allSatisfy(\.isFinite))
            XCTAssertTrue(buffer.right.allSatisfy(\.isFinite))
        }
    }

    func testBufferBoundariesAreSampleIdenticalToOneShotRender() {
        var oneShot = StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0.2
        )
        let expected = oneShot.render(frameCount: 4_097)

        var chunked = StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0.2
        )
        let sizes = [1, 127, 256, 1_024, 2_689]
        var left: [Float] = []
        var right: [Float] = []
        for size in sizes {
            let block = chunked.render(frameCount: size)
            left.append(contentsOf: block.left)
            right.append(contentsOf: block.right)
        }
        XCTAssertEqual(left, expected.left)
        XCTAssertEqual(right, expected.right)
        XCTAssertEqual(chunked.phaseSnapshot, oneShot.phaseSnapshot)
    }

    func testAbruptUpdatePreservesPhaseWithExplicitResidual() {
        let rate = 48_000.0
        var renderer = StereoPCMRenderer(
            sampleRate: rate,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0.2
        )
        _ = renderer.render(frameCount: 1_003)
        let phaseAtUpdate = renderer.phaseSnapshot
        renderer.setFrequencies(left: 440, right: 448, transitionFrames: 0)
        let first = renderer.render(frameCount: 1)

        XCTAssertEqual(Double(first.left[0]), 0.2 * sin(phaseAtUpdate.left), accuracy: 2e-8)
        XCTAssertEqual(Double(first.right[0]), 0.2 * sin(phaseAtUpdate.right), accuracy: 2e-8)
        let expectedLeft = wrap(phaseAtUpdate.left + 2 * .pi * 440 / rate)
        let expectedRight = wrap(phaseAtUpdate.right + 2 * .pi * 448 / rate)
        let residualLeft = angularDistance(renderer.phaseSnapshot.left, expectedLeft)
        let residualRight = angularDistance(renderer.phaseSnapshot.right, expectedRight)
        XCTAssertLessThan(residualLeft, 1e-12)
        XCTAssertLessThan(residualRight, 1e-12)
    }

    func testSmoothFrequencyUpdateIsDeterministicAndPhaseContinuous() {
        var a = StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0.2
        )
        var b = a
        a.setFrequencies(left: 240, right: 252, transitionFrames: 4_800)
        b.setFrequencies(left: 240, right: 252, transitionFrames: 4_800)
        let outputA = a.render(frameCount: 9_600)
        let outputB = b.render(frameCount: 9_600)
        XCTAssertEqual(outputA, outputB)
        XCTAssertEqual(a.phaseSnapshot, b.phaseSnapshot)
        XCTAssertEqual(a.currentFrequencies.left, 240, accuracy: 1e-12)
        XCTAssertEqual(a.currentFrequencies.right, 252, accuracy: 1e-12)
    }

    func testRaisedCosineGainFade() {
        var renderer = StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0
        )
        renderer.setGain(0.2, fadeFrames: 4_800)
        let output = renderer.render(frameCount: 4_801)
        XCTAssertEqual(output.left[0], 0)
        XCTAssertEqual(renderer.currentGain, 0.2, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(peak(output), 0.200_01)
    }

    func testInterleavedOrderingIsLeftThenRight() {
        var renderer = StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0.2,
            initialPhase: .init(left: .pi / 2, right: -.pi / 2)
        )
        let buffer = renderer.render(frameCount: 2)
        let interleaved = buffer.interleaved
        XCTAssertEqual(interleaved[0], buffer.left[0])
        XCTAssertEqual(interleaved[1], buffer.right[0])
        XCTAssertEqual(interleaved[2], buffer.left[1])
        XCTAssertEqual(interleaved[3], buffer.right[1])
        XCTAssertGreaterThan(interleaved[0], 0)
        XCTAssertLessThan(interleaved[1], 0)
    }

    func testCallerOwnedBuffersMatchConvenienceOutputAndPreservePointers() {
        var oracle = StereoPCMRenderer(
            sampleRate: 48_000, leftFrequency: 200, rightFrequency: 210, gain: 0.2
        )
        let expected = oracle.render(frameCount: 4_096)
        var renderer = StereoPCMRenderer(
            sampleRate: 48_000, leftFrequency: 200, rightFrequency: 210, gain: 0.2
        )
        var left = [Float](repeating: -1, count: 4_096)
        var right = [Float](repeating: -1, count: 4_096)
        let leftAddress = left.withUnsafeBufferPointer { $0.baseAddress }
        let rightAddress = right.withUnsafeBufferPointer { $0.baseAddress }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                renderer.render(into: l, right: r)
            }
        }
        XCTAssertEqual(left, expected.left)
        XCTAssertEqual(right, expected.right)
        XCTAssertEqual(leftAddress, left.withUnsafeBufferPointer { $0.baseAddress })
        XCTAssertEqual(rightAddress, right.withUnsafeBufferPointer { $0.baseAddress })
        XCTAssertEqual(renderer.phaseSnapshot, oracle.phaseSnapshot)
    }

    func testSampleRateReconstructionPreservesOscillatorPhase() {
        var renderer48 = StereoPCMRenderer(
            sampleRate: 48_000, leftFrequency: 200,
            rightFrequency: 210, gain: 0.2
        )
        _ = renderer48.render(frameCount: 537)
        let retained = renderer48.phaseSnapshot
        var renderer96 = StereoPCMRenderer(
            sampleRate: 96_000, leftFrequency: 200,
            rightFrequency: 210, gain: 0.2,
            initialPhase: retained
        )
        let first = renderer96.render(frameCount: 1)
        XCTAssertEqual(Double(first.left[0]), 0.2 * sin(retained.left), accuracy: 2e-8)
        XCTAssertEqual(Double(first.right[0]), 0.2 * sin(retained.right), accuracy: 2e-8)
    }

    private func estimateFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        var positiveCrossings: [Int] = []
        for index in 1..<samples.count where samples[index - 1] <= 0 && samples[index] > 0 {
            positiveCrossings.append(index)
        }
        guard let first = positiveCrossings.first, let last = positiveCrossings.last,
              positiveCrossings.count > 1 else { return 0 }
        return Double(positiveCrossings.count - 1) * sampleRate / Double(last - first)
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    private func peak(_ buffer: StereoPCMBuffer) -> Double {
        max(buffer.left.map { abs(Double($0)) }.max() ?? 0,
            buffer.right.map { abs(Double($0)) }.max() ?? 0)
    }

    private func wrap(_ phase: Double) -> Double {
        let remainder = phase.truncatingRemainder(dividingBy: 2 * .pi)
        return remainder >= 0 ? remainder : remainder + 2 * .pi
    }

    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        abs(atan2(sin(a - b), cos(a - b)))
    }
}
