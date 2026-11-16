import XCTest
@testable import MetronomeEngine

@MainActor
final class MetronomeEngineTests: XCTestCase {
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

    func testInvalidSampleRateDoesNotStart() {
        let engine = MetronomeEngine()
        XCTAssertThrowsError(try engine.start(sampleRate: 0))
        XCTAssertNotEqual(engine.state, .playing)
    }
}
