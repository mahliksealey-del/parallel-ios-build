import XCTest
import MetronomeEngine
@testable import Parallel

@MainActor
final class ParallelTests: XCTestCase {
    func testLaunchStatusMessage() {
        XCTAssertEqual(LaunchStatus.message, "Launch successful")
    }

    func testStartIsIdempotentAndUsesMixedSession() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.start()
        XCTAssertEqual(fixture.session.configureCount, 1)
        XCTAssertEqual(fixture.session.activateCount, 1)
        XCTAssertEqual(fixture.engine.startCount, 1)
        XCTAssertEqual(fixture.coordinator.state, .active)
    }

    func testActivationFailureIsVisibleAndStopsIntent() {
        let fixture = makeFixture()
        fixture.session.activationError = TestError.expected
        fixture.coordinator.start()
        guard case .failed = fixture.coordinator.state else { return XCTFail("Expected a visible failure") }
        XCTAssertFalse(fixture.coordinator.userRequestedPlayback)
        XCTAssertEqual(fixture.engine.stopCount, 1)
    }

    func testEngineStartFailureIsVisibleAndRetryable() {
        let fixture = makeFixture()
        fixture.engine.startError = TestError.expected
        fixture.coordinator.start()
        guard case .failed = fixture.coordinator.state else { return XCTFail("Expected a visible failure") }
        XCTAssertFalse(fixture.coordinator.userRequestedPlayback)
        XCTAssertGreaterThanOrEqual(fixture.engine.stopCount, 1)
    }

    func testInterruptionResumesOnlyWithSystemPermission() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.interruptionBegan()
        XCTAssertEqual(fixture.coordinator.state, .interrupted)
        fixture.coordinator.interruptionEnded(shouldResume: true)
        XCTAssertEqual(fixture.engine.startCount, 2)
        XCTAssertEqual(fixture.coordinator.state, .active)
    }

    func testInterruptionWithoutPermissionDoesNotResume() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.interruptionBegan()
        fixture.coordinator.interruptionEnded(shouldResume: false)
        XCTAssertEqual(fixture.engine.startCount, 1)
        XCTAssertFalse(fixture.coordinator.userRequestedPlayback)
        XCTAssertEqual(fixture.coordinator.state, .inactive)
    }

    func testUserStopDuringInterruptionPreventsResume() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.interruptionBegan()
        fixture.coordinator.stop()
        fixture.coordinator.interruptionEnded(shouldResume: true)
        XCTAssertEqual(fixture.engine.startCount, 1)
        XCTAssertEqual(fixture.coordinator.state, .inactive)
    }

    func testOutputRemovalPausesBeforeSpeakerFallback() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.outputDeviceWasRemoved()
        XCTAssertFalse(fixture.coordinator.userRequestedPlayback)
        XCTAssertEqual(fixture.session.deactivateCount, 1)
        guard case .failed(let message) = fixture.coordinator.state else { return XCTFail("Expected warning") }
        XCTAssertTrue(message.contains("speaker"))
    }

    func testRouteRefreshReadsActualFormat() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.route?.sampleRate, 48_000)
        XCTAssertEqual(fixture.coordinator.route?.outputChannels, 2)
        XCTAssertEqual(fixture.coordinator.route?.ioBufferDuration, 0.005)
    }

    func testMediaResetReconfiguresAndRebuildsForRecordedIntent() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.mediaServicesWereLost()
        fixture.coordinator.mediaServicesWereReset()
        XCTAssertEqual(fixture.session.configureCount, 2)
        XCTAssertEqual(fixture.engine.startCount, 2)
        XCTAssertEqual(fixture.coordinator.state, .active)
    }

    private func makeFixture() -> (coordinator: AudioSessionCoordinator, session: FakeSession, engine: FakeEngine) {
        let session = FakeSession()
        let engine = FakeEngine()
        let coordinator = AudioSessionCoordinator(session: session, engine: engine, observeSystemNotifications: false)
        return (coordinator, session, engine)
    }
}

private enum TestError: Error { case expected }

private final class FakeSession: AudioSessionControlling {
    var sampleRate = 48_000.0
    var outputNumberOfChannels = 2
    var ioBufferDuration = 0.005
    var outputNames = ["Test headphones"]
    var configureCount = 0
    var activateCount = 0
    var deactivateCount = 0
    var activationError: Error?
    func configureForMixedPlayback() throws { configureCount += 1 }
    func activate() throws { activateCount += 1; if let activationError { throw activationError } }
    func deactivate() throws { deactivateCount += 1 }
}

@MainActor
private final class FakeEngine: MetronomeEngineProtocol {
    var state: MetronomeEngineState = .stopped
    var bpm = 120.0
    var gain: Float = 0.65
    var onStateChange: ((MetronomeEngineState) -> Void)?
    var onConfigurationChange: (() -> Void)?
    var startCount = 0
    var stopCount = 0
    var startError: Error?
    func setBPM(_ bpm: Double) throws { self.bpm = bpm }
    func setGain(_ gain: Float) throws { self.gain = gain }
    func start(sampleRate: Double) throws {
        startCount += 1
        if let startError { throw startError }
        state = .playing
    }
    func stop() { stopCount += 1; state = .stopped }
    func markInterrupted() { state = .interrupted }
    func markRecovering() { state = .recovering }
}
