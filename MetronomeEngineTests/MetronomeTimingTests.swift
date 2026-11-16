import XCTest
@testable import MetronomeEngine

final class MetronomeTimingTests: XCTestCase {
    func testBPMValidation() {
        XCTAssertNoThrow(try BeatFrameScheduler(bpm: 30, sampleRate: 48_000))
        XCTAssertNoThrow(try BeatFrameScheduler(bpm: 300, sampleRate: 48_000))
        XCTAssertThrowsError(try BeatFrameScheduler(bpm: 29.9, sampleRate: 48_000))
        XCTAssertThrowsError(try BeatFrameScheduler(bpm: .nan, sampleRate: 48_000))
    }

    func testBeatDurationAndIntegralFrameInterval() throws {
        var scheduler = try BeatFrameScheduler(bpm: 120, sampleRate: 48_000)
        XCTAssertEqual(scheduler.beatDuration, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(scheduler.nextIntervalFrames(), 24_000)
    }

    func testFractionalFramesDoNotAccumulateDrift() throws {
        var scheduler = try BeatFrameScheduler(bpm: 137, sampleRate: 44_100)
        for _ in 0..<100_000 { _ = scheduler.nextIntervalFrames() }
        let drift = abs(Double(scheduler.cumulativeEmittedFrame) - scheduler.cumulativeIdealFrame)
        XCTAssertLessThanOrEqual(drift, 0.5)
    }

    func testAccentSequenceRepeatsEveryFourBeats() {
        var sequence = AccentSequence()
        XCTAssertEqual((0..<8).map { _ in sequence.nextIsAccent() },
                       [true, false, false, false, true, false, false, false])
    }
}
