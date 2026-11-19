import XCTest
@testable import PsychoacousticDSP

final class LayeredPsychoacousticRendererTests: XCTestCase {
    func testBinauralChannelsRemainIndependent() {
        let output = render(mode: .binaural, frames: 48_000)
        XCTAssertNotEqual(output.left, output.right)
        XCTAssertLessThan(output.left.map { abs($0) }.max()!, 0.5)
        XCTAssertLessThan(output.right.map { abs($0) }.max()!, 0.5)
    }

    func testMonauralAndIsochronicAreDiotic() {
        for mode in [PsychoacousticMode.monaural, .isochronic] {
            let output = render(mode: mode, frames: 8_192)
            XCTAssertEqual(output.left, output.right)
        }
    }

    func testIsochronicGateHasExpectedSilentAndOpenSamples() {
        let output = render(mode: .isochronic, frames: 4_801, gain: 0.5)
        XCTAssertEqual(output.left[0], 0, accuracy: 1e-7)
        XCTAssertGreaterThan(output.left[2_400...2_500].map { abs($0) }.max()!, 0.30)
    }

    func testNoiseIsDeterministicFiniteAndBounded() {
        let levels = NoiseLevels(white: 0.25, pink: 0.2, brown: 0.15)
        var first = LayeredPsychoacousticRenderer(sampleRate: 48_000, mode: .monaural,
            carrierHz: 200, beatHz: 10, toneGain: 0, noise: levels, seed: 42)
        var second = first
        var a = StereoPCMBuffer(frameCount: 16_384)
        var b = StereoPCMBuffer(frameCount: 16_384)
        a.left.withUnsafeMutableBufferPointer { l in a.right.withUnsafeMutableBufferPointer { r in first.render(into: l, right: r) } }
        b.left.withUnsafeMutableBufferPointer { l in b.right.withUnsafeMutableBufferPointer { r in second.render(into: l, right: r) } }
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.interleaved.allSatisfy { $0.isFinite && abs($0) < 1 })
        XCTAssertGreaterThan(a.left.map { abs($0) }.max()!, 0.05)
    }

    func testChunkingDoesNotChangeOutput() {
        var oneShot = LayeredPsychoacousticRenderer(sampleRate: 44_100, mode: .monaural,
            carrierHz: 180, beatHz: 7, toneGain: 0.3, noise: .init(pink: 0.1))
        var chunked = oneShot
        var expected = StereoPCMBuffer(frameCount: 4_096)
        expected.left.withUnsafeMutableBufferPointer { l in expected.right.withUnsafeMutableBufferPointer { r in oneShot.render(into: l, right: r) } }
        var actualLeft = [Float]()
        var actualRight = [Float]()
        for count in [17, 511, 1_024, 2_544] {
            var part = StereoPCMBuffer(frameCount: count)
            part.left.withUnsafeMutableBufferPointer { l in part.right.withUnsafeMutableBufferPointer { r in chunked.render(into: l, right: r) } }
            actualLeft += part.left
            actualRight += part.right
        }
        XCTAssertEqual(expected.left, actualLeft)
        XCTAssertEqual(expected.right, actualRight)
    }

    func testRealtimeLayerCommandsChangeModeAndNoiseWithoutStopping() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        owner.armAfterVerifiedStereoRoute()
        var stream = RealtimeControlledLayeredStream(
            renderer: .init(sampleRate: 48_000, mode: .binaural,
                            carrierHz: 200, beatHz: 10, toneGain: 0.3),
            control: owner.makeRenderPort()
        )
        XCTAssertTrue(owner.sendMode(.monaural))
        XCTAssertTrue(owner.sendNoise(.init(white: 0.1, pink: 0.05, brown: 0.02)))
        var output = StereoPCMBuffer(frameCount: 2_048)
        output.left.withUnsafeMutableBufferPointer { left in
            output.right.withUnsafeMutableBufferPointer { right in
                stream.render(into: left, right: right)
            }
        }
        XCTAssertEqual(output.left, output.right)
        XCTAssertTrue(output.interleaved.allSatisfy { $0.isFinite && abs($0) < 1 })
        XCTAssertFalse(stream.isStopped)
    }

    private func render(mode: PsychoacousticMode, frames: Int, gain: Double = 0.4) -> StereoPCMBuffer {
        var renderer = LayeredPsychoacousticRenderer(sampleRate: 48_000, mode: mode,
            carrierHz: 200, beatHz: 10, toneGain: gain)
        var output = StereoPCMBuffer(frameCount: frames)
        output.left.withUnsafeMutableBufferPointer { l in output.right.withUnsafeMutableBufferPointer { r in renderer.render(into: l, right: r) } }
        return output
    }
}
