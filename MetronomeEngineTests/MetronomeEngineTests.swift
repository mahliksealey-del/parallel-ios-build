import XCTest
@testable import MetronomeEngine

@MainActor
final class MetronomeEngineTests: XCTestCase {
    func testClickBoostIsOptInAndRequiresStoppedRenderState() throws {
        let engine = MetronomeEngine()
        XCTAssertFalse(engine.boostedClicks)
        XCTAssertNoThrow(try engine.setBoostedClicks(true))
        XCTAssertTrue(engine.boostedClicks)
        _ = try engine.makeNodes(sampleRate: 48_000)
        engine.markPlaying()
        XCTAssertThrowsError(try engine.setBoostedClicks(false))
        XCTAssertTrue(engine.boostedClicks)
        engine.stop()
        XCTAssertNoThrow(try engine.setBoostedClicks(false))
        XCTAssertFalse(engine.boostedClicks)
    }

    func testGainBounds() throws {
        let engine = MetronomeEngine()
        XCTAssertNoThrow(try engine.setGain(0))
        XCTAssertNoThrow(try engine.setGain(1))
        XCTAssertThrowsError(try engine.setGain(-0.01))
        XCTAssertThrowsError(try engine.setGain(1.01))
        XCTAssertThrowsError(try engine.setGain(.nan))
    }

    func testTempoBounds() throws {
        let engine = MetronomeEngine()
        XCTAssertNoThrow(try engine.setBPM(30))
        XCTAssertNoThrow(try engine.setBPM(300))
        XCTAssertThrowsError(try engine.setBPM(301))
    }

    func testStopIsIdempotent() {
        let engine = MetronomeEngine()
        engine.stop()
        engine.stop()
        XCTAssertEqual(engine.state, .stopped)
    }

    func testInvalidSampleRateDoesNotCreateNodes() {
        let engine = MetronomeEngine()
        XCTAssertThrowsError(try engine.makeNodes(sampleRate: 0))
        XCTAssertThrowsError(try engine.makeNodes(sampleRate: .nan))
        XCTAssertNotEqual(engine.state, .playing)
    }

    func testNodeConstructionLeavesGraphOwnershipToCaller() throws {
        let engine = MetronomeEngine()
        try engine.setGain(0.4)
        let nodes = try engine.makeNodes(sampleRate: 48_000)
        XCTAssertEqual(nodes.format.sampleRate, 48_000)
        XCTAssertEqual(nodes.gainMixer.outputVolume, 0.4, accuracy: 0.0001)
        XCTAssertEqual(engine.state, .starting)
        try engine.setGain(0.2)
        XCTAssertEqual(nodes.gainMixer.outputVolume, 0.2, accuracy: 0.0001)
        engine.markPlaying()
        XCTAssertEqual(engine.state, .playing)
        XCTAssertThrowsError(try engine.setBPM(130))
        XCTAssertThrowsError(try engine.makeNodes(sampleRate: 48_000))
    }

    func testCanBuildAgainAfterStop() throws {
        let engine = MetronomeEngine()
        _ = try engine.makeNodes(sampleRate: 48_000)
        engine.markPlaying()
        engine.stop()
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertNoThrow(try engine.makeNodes(sampleRate: 44_100))
    }
}
