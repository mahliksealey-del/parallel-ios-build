import XCTest
@testable import Parallel

@MainActor
final class ParallelTests: XCTestCase {
    func testAppRootInjectsOneSharedSession() {
        let container = ParallelAudioContainer()
        XCTAssertTrue(container.metronome.coordinator === container.session)
    }

    func testAppRootSharesSessionWithFirstMediaMixer() {
        let container = ParallelAudioContainer()
        XCTAssertTrue(container.metronome.coordinator === container.session)
        XCTAssertFalse(container.media.hasVideo)
        XCTAssertTrue(container.session.requestedSources.isEmpty)
        // First media slot is registered by the root container.
        XCTAssertFalse(container.session.register(FakeSource(), for: .media(0)))
    }

    func testMediaMixerRequiresImportedFileBeforePlayback() {
        let f = makeFixture()
        let media = MediaMixerViewModel(coordinator: f.coordinator)
        media.togglePlayback()
        XCTAssertNotNil(media.errorMessage)
        XCTAssertFalse(media.isPlaying)
        XCTAssertEqual(f.session.activateCount, 0)
        XCTAssertTrue(f.coordinator.requestedSources.isEmpty)
    }

    func testMediaMixerRejectsInvalidVolumeInput() {
        let f = makeFixture()
        let media = MediaMixerViewModel(coordinator: f.coordinator)
        media.volume = 1.5
        media.applyVolume()
        XCTAssertNotNil(media.errorMessage)
        media.volume = 0.3
        media.applyVolume()
        XCTAssertEqual(media.volume, 0.3, accuracy: 0.0001)
    }

    func testManagedVideoStoreRejectsUnsupportedFileType() {
        let input = URL(fileURLWithPath: "/tmp/test-audio-only.txt")
        XCTAssertThrowsError(try ManagedVideoFileStore.copy(from: input))
    }

    func testLaunchStatusMessage() {
        XCTAssertEqual(LaunchStatus.message, "Launch successful")
    }

    func testStartIsIdempotentAndUsesMixedSession() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.start()
        XCTAssertEqual(fixture.session.configureCount, 1)
        XCTAssertEqual(fixture.session.activateCount, 1)
        XCTAssertEqual(fixture.graph.startCount, 1)
        XCTAssertEqual(fixture.coordinator.state, .active)
    }

    func testActivationFailureIsVisibleAndStopsIntent() {
        let fixture = makeFixture()
        fixture.session.activationError = TestError.expected
        fixture.coordinator.start()
        guard case .failed = fixture.coordinator.state else { return XCTFail("Expected a visible failure") }
        XCTAssertFalse(fixture.coordinator.userRequestedPlayback)
        XCTAssertEqual(fixture.graph.stopCount, 1)
    }

    func testEngineStartFailureIsVisibleAndRetryable() {
        let fixture = makeFixture()
        fixture.graph.startError = TestError.expected
        fixture.coordinator.start()
        guard case .failed = fixture.coordinator.state else { return XCTFail("Expected a visible failure") }
        XCTAssertFalse(fixture.coordinator.userRequestedPlayback)
        XCTAssertGreaterThanOrEqual(fixture.graph.stopCount, 1)
    }

    func testInterruptionResumesOnlyWithSystemPermission() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.interruptionBegan()
        XCTAssertEqual(fixture.coordinator.state, .interrupted)
        fixture.coordinator.interruptionEnded(shouldResume: true)
        XCTAssertEqual(fixture.graph.startCount, 2)
        XCTAssertEqual(fixture.coordinator.state, .active)
    }

    func testInterruptionWithoutPermissionDoesNotResume() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.interruptionBegan()
        fixture.coordinator.interruptionEnded(shouldResume: false)
        XCTAssertEqual(fixture.graph.startCount, 1)
        XCTAssertFalse(fixture.coordinator.userRequestedPlayback)
        XCTAssertEqual(fixture.coordinator.state, .inactive)
    }

    func testUserStopDuringInterruptionPreventsResume() {
        let fixture = makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.interruptionBegan()
        fixture.coordinator.stop()
        fixture.coordinator.interruptionEnded(shouldResume: true)
        XCTAssertEqual(fixture.graph.startCount, 1)
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
        XCTAssertEqual(fixture.graph.startCount, 2)
        XCTAssertEqual(fixture.coordinator.state, .active)
    }


    func testSecondSourceDoesNotReactivateSession() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(0))
        XCTAssertEqual(f.session.configureCount, 1)
        XCTAssertEqual(f.session.activateCount, 1)
        XCTAssertEqual(f.graph.startCount, 1)
        XCTAssertEqual(media.startCount, 1)
        XCTAssertEqual(f.coordinator.requestedSources.count, 2)
    }

    func testStoppingMetronomeKeepsMediaAndSessionAlive() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(0))
        f.coordinator.stop()
        XCTAssertFalse(f.coordinator.userRequestedPlayback)
        XCTAssertEqual(f.graph.stopCount, 1)
        XCTAssertEqual(media.stopCount, 0)
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(f.coordinator.state, .active)
        f.coordinator.stopPlayback(for: .media(0))
        XCTAssertEqual(f.session.deactivateCount, 1)
        XCTAssertEqual(f.coordinator.state, .inactive)
    }

    func testMediaFirstThenMetronomeUsesOneSession() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(1)))
        f.coordinator.requestPlayback(for: .media(1))
        f.coordinator.start()
        XCTAssertEqual(f.session.activateCount, 1)
        XCTAssertEqual(media.startCount, 1)
        XCTAssertEqual(f.graph.startCount, 1)
        f.coordinator.stopPlayback(for: .media(1))
        XCTAssertEqual(f.session.deactivateCount, 0)
        f.coordinator.stop()
        XCTAssertEqual(f.session.deactivateCount, 1)
    }

    func testMediaOnlyPlaybackAndRepeatedStopAreIdempotent() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(2)))
        f.coordinator.requestPlayback(for: .media(2))
        f.coordinator.requestPlayback(for: .media(2))
        XCTAssertEqual(media.startCount, 1)
        XCTAssertEqual(f.graph.startCount, 0)
        f.coordinator.stopPlayback(for: .media(2))
        f.coordinator.stopPlayback(for: .media(2))
        XCTAssertEqual(media.stopCount, 1)
        XCTAssertEqual(f.session.deactivateCount, 1)
    }

    func testFailureOfSecondSourcePreservesCurrentPlayback() {
        let f = makeFixture()
        let media = FakeSource()
        media.startError = TestError.expected
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        var error: String?
        f.coordinator.onSourceError = { _, message in error = message }
        f.coordinator.requestPlayback(for: .media(0))
        XCTAssertNotNil(error)
        XCTAssertEqual(f.coordinator.state, .active)
        XCTAssertEqual(f.coordinator.requestedSources, Set([AudioSourceID.metronome]))
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(f.graph.stopCount, 0)
    }

    func testBothSourcesRecoverFromPermittedInterruption() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(0))
        f.coordinator.interruptionBegan()
        XCTAssertEqual(media.interruptCount, 1)
        XCTAssertEqual(f.graph.interruptCount, 1)
        f.coordinator.interruptionEnded(shouldResume: true)
        XCTAssertEqual(media.startCount, 2)
        XCTAssertEqual(f.graph.startCount, 2)
        XCTAssertEqual(f.session.activateCount, 2)
    }

    func testOutputRemovalStopsEveryRegisteredActiveSource() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(0))
        f.coordinator.outputDeviceWasRemoved()
        XCTAssertEqual(media.stopCount, 1)
        XCTAssertEqual(f.graph.stopCount, 1)
        XCTAssertTrue(f.coordinator.requestedSources.isEmpty)
        XCTAssertEqual(f.session.deactivateCount, 1)
    }

    func testUnregisterReleasesActiveMediaAndRetainsMetronome() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(0))
        f.coordinator.unregister(.media(0))
        XCTAssertEqual(media.stopCount, 1)
        XCTAssertEqual(f.session.deactivateCount, 0)
        f.coordinator.stop()
        XCTAssertEqual(f.session.deactivateCount, 1)
    }

    func testRegistrationRejectsDuplicateAndMetronomeReplacement() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertFalse(f.coordinator.register(media, for: .metronome))
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        XCTAssertFalse(f.coordinator.register(FakeSource(), for: .media(0)))
    }

    func testGraphReconfigurationPreservesMediaSource() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(0))
        f.graph.onConfigurationChange?()
        XCTAssertEqual(f.graph.startCount, 2)
        XCTAssertEqual(media.startCount, 1)
        XCTAssertEqual(media.stopCount, 0)
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(f.coordinator.state, .active)
    }

    func testMediaServicesResetRestoresAllRequestedSources() {
        let f = makeFixture()
        let media = FakeSource()
        XCTAssertTrue(f.coordinator.register(media, for: .media(0)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(0))
        f.coordinator.mediaServicesWereLost()
        f.coordinator.mediaServicesWereReset()
        XCTAssertEqual(media.startCount, 2)
        XCTAssertEqual(f.graph.startCount, 2)
        XCTAssertEqual(f.session.activateCount, 2)
    }

    func testUnregisteredMediaCannotActivateSession() {
        let f = makeFixture()
        f.coordinator.requestPlayback(for: .media(99))
        XCTAssertEqual(f.session.activateCount, 0)
        XCTAssertTrue(f.coordinator.requestedSources.isEmpty)
    }

    private func makeFixture() -> (coordinator: AudioSessionCoordinator, session: FakeSession, graph: FakeGraph) {
        let session = FakeSession()
        let graph = FakeGraph()
        let coordinator = AudioSessionCoordinator(session: session, graph: graph, observeSystemNotifications: false)
        return (coordinator, session, graph)
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
private class FakeSource: AudioPlaybackSource {
    var startCount = 0
    var stopCount = 0
    var interruptCount = 0
    var recoveryCount = 0
    var startError: Error?
    func start(sampleRate: Double) throws {
        startCount += 1
        if let startError { throw startError }
    }
    func stop() { stopCount += 1 }
    func markInterrupted() { interruptCount += 1 }
    func markRecovering() { recoveryCount += 1 }
}

@MainActor
private final class FakeGraph: FakeSource, AudioGraphControlling {
    var onConfigurationChange: (() -> Void)?
}
