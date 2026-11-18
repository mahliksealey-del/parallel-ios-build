import XCTest
@testable import PsychoacousticDSP

final class ReferenceFixtureTests: XCTestCase {
    func testAllReferenceFixturesAreFiniteAndRepeatableAtThreeSampleRates() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            for fixture in P3ReferenceFixture.allCases {
                let first = ReferenceFixtureRenderer.render(fixture, sampleRate: rate, duration: 2)
                let second = ReferenceFixtureRenderer.render(fixture, sampleRate: rate, duration: 2)
                XCTAssertEqual(first, second, "\(fixture) at \(rate)")
                XCTAssertTrue(first.left.allSatisfy(\.isFinite))
                XCTAssertTrue(first.right.allSatisfy(\.isFinite))
                XCTAssertLessThanOrEqual(peak(first), 0.200_01)
            }
        }
    }

    func testC01ThroughC03ClosedFormValues() {
        let cases: [(P3ReferenceFixture, Double, Double)] = [
            (.c01, 200, 210),
            (.c02, 440, 448),
            (.c03, 200, 200),
        ]
        for (fixture, left, right) in cases {
            let buffer = ReferenceFixtureRenderer.render(fixture, sampleRate: 48_000, duration: 2)
            XCTAssertEqual(estimateFrequency(buffer.left), left, accuracy: 0.2)
            XCTAssertEqual(estimateFrequency(buffer.right), right, accuracy: 0.2)
            XCTAssertEqual(rms(buffer.left), 0.2 / sqrt(2), accuracy: 0.000_02)
            XCTAssertEqual(rms(buffer.right), 0.2 / sqrt(2), accuracy: 0.000_02)
        }
    }

    func testC04MonauralBeatContainsBothTonesAndIsDiotic() {
        let buffer = ReferenceFixtureRenderer.render(.c04, sampleRate: 48_000, duration: 2)
        XCTAssertEqual(buffer.left, buffer.right)
        XCTAssertEqual(projectionMagnitude(buffer.left, frequency: 200), 0.1, accuracy: 0.000_02)
        XCTAssertEqual(projectionMagnitude(buffer.left, frequency: 210), 0.1, accuracy: 0.000_02)
        XCTAssertEqual(rms(buffer.left), 0.1, accuracy: 0.000_02)
    }

    func testC05AMHasExpectedCarrierSidebandsAndGain() {
        let buffer = ReferenceFixtureRenderer.render(.c05, sampleRate: 48_000, duration: 2)
        XCTAssertEqual(buffer.left, buffer.right)
        XCTAssertEqual(projectionMagnitude(buffer.left, frequency: 200), 0.1, accuracy: 0.000_02)
        XCTAssertEqual(projectionMagnitude(buffer.left, frequency: 190), 0.04, accuracy: 0.000_02)
        XCTAssertEqual(projectionMagnitude(buffer.left, frequency: 210), 0.04, accuracy: 0.000_02)
        let expectedRMS = 0.2 * sqrt((0.5 * 0.5 + 0.4 * 0.4 / 2) / 2)
        XCTAssertEqual(rms(buffer.left), expectedRMS, accuracy: 0.000_02)
    }

    func testC06IsContinuousSweepWithFadedEdges() {
        let rate = 48_000.0
        let buffer = ReferenceFixtureRenderer.render(.c06, sampleRate: rate, duration: 30)
        let firstTenMilliseconds = buffer.left.prefix(Int(rate * 0.01))
        let lastTenMilliseconds = buffer.left.suffix(Int(rate * 0.01))
        XCTAssertLessThan(firstTenMilliseconds.map { abs($0) }.max() ?? 1, 0.001)
        XCTAssertLessThan(lastTenMilliseconds.map { abs($0) }.max() ?? 1, 0.001)
        XCTAssertLessThanOrEqual(peak(buffer), 0.200_01)
    }

    private func estimateFrequency(_ samples: [Float], sampleRate: Double = 48_000) -> Double {
        var crossings: [Int] = []
        for index in 1..<samples.count where samples[index - 1] <= 0 && samples[index] > 0 {
            crossings.append(index)
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 1 else { return 0 }
        return Double(crossings.count - 1) * sampleRate / Double(last - first)
    }

    private func projectionMagnitude(_ samples: [Float], frequency: Double) -> Double {
        let rate = 48_000.0
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / rate
            real += Double(sample) * cos(phase)
            imaginary -= Double(sample) * sin(phase)
        }
        return 2 * hypot(real, imaginary) / Double(samples.count)
    }

    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }

    private func peak(_ buffer: StereoPCMBuffer) -> Double {
        max(buffer.left.map { abs(Double($0)) }.max() ?? 0,
            buffer.right.map { abs(Double($0)) }.max() ?? 0)
    }
}
