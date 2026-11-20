import AVFoundation
import MetronomeEngine
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

    func testContainerOwnsExactlyThreeRegisteredSlots() {
        let container = ParallelAudioContainer()
        XCTAssertEqual(container.videos.count, 3)
        XCTAssertEqual(container.videos.map(\.slot), [0, 1, 2])
        XCTAssertTrue(container.media === container.videos[0])
        XCTAssertEqual(Set(container.videos.map(\.slot)).count, 3)
        for index in 0..<3 {
            XCTAssertFalse(container.session.register(FakeSource(), for: .media(index)))
        }
        XCTAssertTrue(container.session.requestedSources.isEmpty)
    }

    func testMediaSlotIdentityAndIndependentLevels() {
        let f = makeFixture()
        let slots = (0..<3).map { MediaMixerViewModel(coordinator: f.coordinator, slot: $0) }
        XCTAssertEqual(slots.map(\.slot), [0, 1, 2])
        slots[0].volume = 0.2
        slots[1].volume = 0.4
        slots[2].volume = 0.8
        slots.forEach { $0.applyVolume() }
        XCTAssertEqual(slots.map(\.volume), [0.2, 0.4, 0.8])
        XCTAssertTrue(slots.allSatisfy { !$0.hasVideo && !$0.isPlaying })
        XCTAssertEqual(f.session.activateCount, 0)
    }

    func testThreeIndependentMediaSlotsRefusePlaybackBeforeImport() {
        let f = makeFixture()
        let slots = (0..<3).map { MediaMixerViewModel(coordinator: f.coordinator, slot: $0) }
        slots.forEach { $0.togglePlayback() }
        XCTAssertTrue(slots.allSatisfy { $0.errorMessage != nil && !$0.isPlaying })
        XCTAssertTrue(f.coordinator.requestedSources.isEmpty)
        XCTAssertEqual(f.session.activateCount, 0)
    }

    func testThreeVideoSourcesAndMetronomeShareOneActivation() {
        let f = makeFixture()
        let players = (0..<3).map { _ in FakeSource() }
        for index in 0..<3 {
            XCTAssertTrue(f.coordinator.register(players[index], for: .media(index)))
        }
        f.coordinator.start()
        for index in 0..<3 { f.coordinator.requestPlayback(for: .media(index)) }
        XCTAssertEqual(f.session.configureCount, 1)
        XCTAssertEqual(f.session.activateCount, 1)
        XCTAssertEqual(f.graph.startCount, 1)
        XCTAssertEqual(players.map(\.startCount), [1, 1, 1])
        XCTAssertEqual(f.coordinator.requestedSources.count, 4)
    }

    func testPausingMiddleVideoPreservesBothOthersAndMetronome() {
        let f = makeFixture()
        let players = (0..<3).map { _ in FakeSource() }
        for index in 0..<3 {
            XCTAssertTrue(f.coordinator.register(players[index], for: .media(index)))
            f.coordinator.requestPlayback(for: .media(index))
        }
        f.coordinator.start()
        f.coordinator.stopPlayback(for: .media(1))
        XCTAssertEqual(players.map(\.stopCount), [0, 1, 0])
        XCTAssertEqual(f.coordinator.requestedSources,
                       Set([.media(0), .media(2), .metronome]))
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(f.graph.stopCount, 0)
    }

    func testThreeMediaOnlyPlayersReleaseSessionOnlyAfterLastStop() {
        let f = makeFixture()
        let players = (0..<3).map { _ in FakeSource() }
        for index in 0..<3 {
            XCTAssertTrue(f.coordinator.register(players[index], for: .media(index)))
            f.coordinator.requestPlayback(for: .media(index))
        }
        XCTAssertEqual(f.session.activateCount, 1)
        XCTAssertEqual(f.graph.startCount, 0)
        f.coordinator.stopPlayback(for: .media(0))
        f.coordinator.stopPlayback(for: .media(1))
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(f.coordinator.requestedSources, Set([.media(2)]))
        f.coordinator.stopPlayback(for: .media(2))
        XCTAssertEqual(f.session.deactivateCount, 1)
        XCTAssertTrue(f.coordinator.requestedSources.isEmpty)
    }

    func testSourceErrorsAreRoutedToCorrectVideoSlot() {
        let container = ParallelAudioContainer()
        container.session.onSourceError?(.media(1), "Video 2 failure")
        XCTAssertNil(container.videos[0].errorMessage)
        XCTAssertEqual(container.videos[1].errorMessage, "Video 2 failure")
        XCTAssertNil(container.videos[2].errorMessage)
        container.session.onSourceError?(.media(2), "Video 3 failure")
        XCTAssertNil(container.videos[0].errorMessage)
        XCTAssertEqual(container.videos[1].errorMessage, "Video 2 failure")
        XCTAssertEqual(container.videos[2].errorMessage, "Video 3 failure")
    }

    func testAllThreeVideoSurfacesDetachIndependentlyInBackground() {
        let canvases = (0..<3).map { _ in PlayerCanvas(frame: .zero) }
        let players = (0..<3).map { _ in AVPlayer() }
        for index in 0..<3 {
            MediaMixerViewModel.configureForBackgroundPlayback(players[index])
            XCTAssertEqual(players[index].audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)
            canvases[index].updatePresentation(player: players[index], isForeground: true)
            XCTAssertTrue(canvases[index].playerLayer.player === players[index])
        }
        for index in 0..<3 {
            canvases[index].updatePresentation(player: players[index], isForeground: false)
            XCTAssertNil(canvases[index].playerLayer.player)
        }
        for index in 0..<3 {
            canvases[index].updatePresentation(player: players[index], isForeground: true)
            XCTAssertTrue(canvases[index].playerLayer.player === players[index])
        }
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

    func testVideoPlayerRequestsBackgroundAudioContinuation() {
        let player = AVPlayer()
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        MediaMixerViewModel.configureForBackgroundPlayback(player)
        XCTAssertEqual(player.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)
    }

    func testVideoSurfaceDisconnectsDisplayWithoutReplacingPlayer() {
        let canvas = PlayerCanvas(frame: .zero)
        let player = AVPlayer()
        canvas.updatePresentation(player: player, isForeground: true)
        XCTAssertTrue(canvas.playerLayer.player === player)
        canvas.updatePresentation(player: player, isForeground: false)
        XCTAssertNil(canvas.playerLayer.player)
        canvas.updatePresentation(player: player, isForeground: true)
        XCTAssertTrue(canvas.playerLayer.player === player)
    }

    func testSeekTargetClampsAndRejectsInvalidDurations() {
        XCTAssertEqual(MediaMixerViewModel.validatedSeekTime(-20, duration: 120), 0)
        XCTAssertEqual(MediaMixerViewModel.validatedSeekTime(35.5, duration: 120), 35.5)
        XCTAssertEqual(MediaMixerViewModel.validatedSeekTime(200, duration: 120), 120)
        XCTAssertNil(MediaMixerViewModel.validatedSeekTime(20, duration: 0))
        XCTAssertNil(MediaMixerViewModel.validatedSeekTime(.nan, duration: 120))
        XCTAssertNil(MediaMixerViewModel.validatedSeekTime(10, duration: .infinity))
    }

    func testPlayerTimelineTimeFormatting() {
        XCTAssertEqual(MediaMixerViewModel.formatTimestamp(0), "0:00")
        XCTAssertEqual(MediaMixerViewModel.formatTimestamp(65.4), "1:05")
        XCTAssertEqual(MediaMixerViewModel.formatTimestamp(3601.9), "60:01")
        XCTAssertEqual(MediaMixerViewModel.formatTimestamp(.nan), "0:00")
    }

    func testSeekingWithoutMediaDoesNotActivateAudio() {
        let f = makeFixture()
        let video = MediaMixerViewModel(coordinator: f.coordinator, slot: 2)
        video.seek(to: 20)
        XCTAssertFalse(video.canSeek)
        XCTAssertEqual(video.currentSeconds, 0)
        XCTAssertEqual(f.session.activateCount, 0)
        XCTAssertTrue(f.coordinator.requestedSources.isEmpty)
    }

    func testVideoOnePiPLayerPolicyDoesNotDisableBackgroundAudio() {
        XCTAssertTrue(VideoPiPCoordinator.shouldAttachVideoLayer(
            foreground: true, pipActive: false, pipStarting: false))
        XCTAssertTrue(VideoPiPCoordinator.shouldAttachVideoLayer(
            foreground: false, pipActive: false, pipStarting: true))
        XCTAssertTrue(VideoPiPCoordinator.shouldAttachVideoLayer(
            foreground: false, pipActive: true, pipStarting: false))
        XCTAssertFalse(VideoPiPCoordinator.shouldAttachVideoLayer(
            foreground: false, pipActive: false, pipStarting: false))
    }

    func testPiPControllerRejectsNonPrimarySlotWithoutChangingPlaybackIntent() {
        let f = makeFixture()
        let secondVideo = MediaMixerViewModel(coordinator: f.coordinator, slot: 1)
        let pip = VideoPiPCoordinator()
        pip.toggle(for: secondVideo)
        XCTAssertFalse(pip.isActive)
        XCTAssertFalse(pip.isStarting)
        XCTAssertNil(pip.errorMessage)
        XCTAssertTrue(f.coordinator.requestedSources.isEmpty)
    }

    func testMetronomeButtonResetsWhenVideosKeepSharedSessionActive() {
        let f = makeFixture()
        let video = FakeSource()
        XCTAssertTrue(f.coordinator.register(video, for: .media(0)))
        f.coordinator.requestPlayback(for: .media(0))
        let engine = MetronomeEngine()
        let vm = MetronomeViewModel(engine: engine, coordinator: f.coordinator)
        XCTAssertFalse(vm.isPlaying)
        vm.togglePlayback()
        XCTAssertTrue(vm.isPlaying)
        vm.togglePlayback()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(f.coordinator.state, .active)
        XCTAssertEqual(f.coordinator.requestedSources, Set([.media(0)]))
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(video.stopCount, 0)
        vm.togglePlayback()
        XCTAssertTrue(vm.isPlaying)
        XCTAssertEqual(f.session.activateCount, 1)
    }

    func testLiveMetronomeTempoRebuildDoesNotStopMediaOrReactivateSession() {
        let f = makeFixture()
        let video = FakeSource()
        XCTAssertTrue(f.coordinator.register(video, for: .media(1)))
        let engine = MetronomeEngine()
        let vm = MetronomeViewModel(engine: engine, coordinator: f.coordinator)
        f.coordinator.requestPlayback(for: .media(1))
        vm.togglePlayback()
        XCTAssertTrue(vm.isPlaying)
        vm.bpm = 174
        vm.applyTempo()
        XCTAssertEqual(engine.bpm, 174)
        XCTAssertEqual(f.graph.startCount, 2)
        XCTAssertEqual(f.graph.stopCount, 1)
        XCTAssertEqual(f.session.activateCount, 1)
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(video.startCount, 1)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertTrue(vm.isPlaying)
    }

    func testFailedMetronomeTempoUpdatePreservesOtherVideos() {
        let f = makeFixture()
        let video = FakeSource()
        XCTAssertTrue(f.coordinator.register(video, for: .media(2)))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(2))
        XCTAssertThrowsError(try f.coordinator.reconfigureMetronome {
            throw TestError.expected
        })
        XCTAssertEqual(f.coordinator.requestedSources, Set([.media(2)]))
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertEqual(f.coordinator.state, .active)
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

    func testPsychoacousticTransportDoesNotInterruptVideoOrMetronome() {
        let f = makeFixture()
        let video = FakeSource()
        let psycho = FakeSource()
        XCTAssertTrue(f.coordinator.register(video, for: .media(2)))
        XCTAssertTrue(f.coordinator.register(psycho, for: .psychoacoustic))
        f.coordinator.start()
        f.coordinator.requestPlayback(for: .media(2))
        f.coordinator.requestPlayback(for: .psychoacoustic)
        XCTAssertEqual(f.session.activateCount, 1)
        XCTAssertEqual(f.graph.startCount, 1)
        XCTAssertEqual(psycho.startCount, 1)
        XCTAssertEqual(video.startCount, 1)

        f.coordinator.stop() // Only metronome
        XCTAssertEqual(f.graph.stopCount, 1)
        XCTAssertEqual(psycho.stopCount, 0)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertEqual(f.session.deactivateCount, 0)
        XCTAssertEqual(f.coordinator.state, .active)

        f.coordinator.stopPlayback(for: .psychoacoustic)
        XCTAssertEqual(psycho.stopCount, 1)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertEqual(f.session.deactivateCount, 0)
        f.coordinator.stopPlayback(for: .media(2))
        XCTAssertEqual(f.session.deactivateCount, 1)
    }

    func testPsychoacousticRouteChangeFailsClosedWithoutStoppingVideo() {
        let f = makeFixture()
        let video = FakeSource()
        let psycho = FakeSource()
        XCTAssertTrue(f.coordinator.register(video, for: .media(0)))
        XCTAssertTrue(f.coordinator.register(psycho, for: .psychoacoustic))
        f.session.hasStereoHeadphoneOutput = true
        f.coordinator.requestPlayback(for: .media(0))
        f.coordinator.requestPlayback(for: .psychoacoustic)
        XCTAssertEqual(psycho.startCount, 1)
        f.session.hasStereoHeadphoneOutput = false
        f.coordinator.routeChanged()
        XCTAssertFalse(f.coordinator.requestedSources.contains(.psychoacoustic))
        XCTAssertTrue(f.coordinator.requestedSources.contains(.media(0)))
        XCTAssertEqual(psycho.stopCount, 1)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertEqual(f.coordinator.state, .active)
        XCTAssertEqual(f.session.deactivateCount, 0)
    }

    func testPsychoacousticConfigurationRecoveryDoesNotRestartVideo() {
        let f = makeFixture()
        let video = FakeSource()
        let psycho = FakeSource()
        XCTAssertTrue(f.coordinator.register(video, for: .media(1)))
        XCTAssertTrue(f.coordinator.register(psycho, for: .psychoacoustic))
        f.coordinator.requestPlayback(for: .media(1))
        f.coordinator.requestPlayback(for: .psychoacoustic)
        f.graph.onConfigurationChange?()
        XCTAssertEqual(video.startCount, 1)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertEqual(psycho.startCount, 2)
        XCTAssertEqual(psycho.recoveryCount, 1)
        XCTAssertEqual(f.session.activateCount, 1)
        XCTAssertEqual(f.coordinator.state, .active)
    }

    func testSessionCompositeEndFadeMath() {
        let envelope = PsychoacousticSessionEnvelope.self
        XCTAssertEqual(envelope.remaining(elapsed: 29, duration: 30), 1)
        XCTAssertEqual(envelope.remaining(elapsed: 31, duration: 30), 0)
        XCTAssertEqual(envelope.gain(remaining: 30), 1, accuracy: 0.000001)
        XCTAssertEqual(envelope.gain(remaining: 10), 1, accuracy: 0.000001)
        XCTAssertEqual(envelope.gain(remaining: 5), 0.5, accuracy: 0.000001)
        XCTAssertEqual(envelope.gain(remaining: 0), 0, accuracy: 0.000001)
        var previous: Float = 1
        for i in 0...1000 {
            let remaining = 10 - Double(i) * 0.01
            let current = envelope.gain(remaining: remaining)
            XCTAssertLessThanOrEqual(current, previous + 0.000001)
            previous = current
        }
    }

    func testPsychoacousticBeatBandLabels() {
        XCTAssertEqual(PsychoacousticViewModel.bandLabel(for: 2), "Delta-range")
        XCTAssertEqual(PsychoacousticViewModel.bandLabel(for: 6), "Theta-range")
        XCTAssertEqual(PsychoacousticViewModel.bandLabel(for: 10), "Alpha-range")
        XCTAssertEqual(PsychoacousticViewModel.bandLabel(for: 20), "Beta-range")
        XCTAssertEqual(PsychoacousticViewModel.bandLabel(for: 40), "Gamma-range")
        XCTAssertEqual(PsychoacousticViewModel.bandLabel(for: .nan), "Not classified")
    }

    func testClickBoostRebuildDoesNotInterruptIndependentVideo() {
        let fixture = makeFixture()
        let video = FakeSource()
        XCTAssertTrue(fixture.coordinator.register(video, for: .media(0)))
        let engine = MetronomeEngine()
        let model = MetronomeViewModel(engine: engine, coordinator: fixture.coordinator)

        fixture.coordinator.requestPlayback(for: .media(0))
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)
        model.boostedClicks = true
        model.applyClickBoost()

        XCTAssertTrue(engine.boostedClicks)
        XCTAssertEqual(fixture.graph.stopCount, 1)
        XCTAssertEqual(fixture.graph.startCount, 2)
        XCTAssertEqual(fixture.session.activateCount, 1)
        XCTAssertEqual(fixture.session.deactivateCount, 0)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertTrue(model.isPlaying)
    }

    func testExtendedPsychoacousticGainIsBounded() {
        let engine = MetronomeEngine()
        let graph = AudioGraphCoordinator(metronome: engine)
        let coordinator = AudioSessionCoordinator(graph: graph, observeSystemNotifications: false)
        let psycho = PsychoacousticViewModel(graph: graph, coordinator: coordinator)
        XCTAssertEqual(psycho.gain, 0.15, accuracy: 0.00001)
        XCTAssertEqual(PsychoacousticGainPolicy.maximum, 0.50)
        psycho.gain = 0.50
        psycho.applyGain()
        XCTAssertNil(psycho.errorMessage)
        psycho.gain = 0.5001
        psycho.applyGain()
        XCTAssertNotNil(psycho.errorMessage)
        XCTAssertTrue(coordinator.requestedSources.isEmpty)
    }

    func testMixerRoutingMuteSoloAndFiniteTrims() {
        let levels = MiniMixerRouting.outputLevels(
            trims: [0.2, 0.4, 0.6, 0.8, 1],
            muted: [1], solo: [0, 1, 4]
        )
        XCTAssertEqual(levels, [0.2, 0, 0, 0, 1])
        XCTAssertEqual(
            MiniMixerRouting.outputLevels(
                trims: [1, .nan, 1, 1, 1], muted: [], solo: []
            ), [1, 0, 1, 1, 1]
        )
        XCTAssertEqual(
            MiniMixerRouting.outputLevels(
                trims: [1, 1, 1, 1, 1], muted: [], solo: []
            ), [1, 1, 1, 1, 1]
        )
    }

    func testFadeDurationsAreMonotonicAndKeepExactEndpoints() {
        for seconds in [5.0, 10.0, 20.0, 30.0] {
            XCTAssertEqual(PsychoacousticSessionEnvelope.gain(remaining: seconds, fadeSeconds: seconds),
                1, accuracy: 0.000001)
            XCTAssertEqual(PsychoacousticSessionEnvelope.gain(remaining: seconds / 2, fadeSeconds: seconds),
                0.5, accuracy: 0.000001)
            XCTAssertEqual(PsychoacousticSessionEnvelope.gain(remaining: 0, fadeSeconds: seconds),
                0, accuracy: 0.000001)
            var previous = Float(1)
            for i in 0...100 {
                let remaining = seconds * (1 - Double(i) / 100)
                let current = PsychoacousticSessionEnvelope.gain(
                    remaining: remaining, fadeSeconds: seconds)
                XCTAssertLessThanOrEqual(current, previous + 0.000001)
                previous = current
            }
        }
    }

    func testExtendedSessionClockUsesHoursOnlyWhenNeeded() {
        XCTAssertEqual(ParallelCountdownFormatter.clock(0), "00:00")
        XCTAssertEqual(ParallelCountdownFormatter.clock(59.2), "01:00")
        XCTAssertEqual(ParallelCountdownFormatter.clock(3599), "59:59")
        XCTAssertEqual(ParallelCountdownFormatter.clock(3600), "1:00:00")
        XCTAssertEqual(ParallelCountdownFormatter.clock(3675), "1:01:15")
        XCTAssertEqual(ParallelCountdownFormatter.clock(86_400), "24:00:00")
        XCTAssertEqual(ParallelCountdownFormatter.clock(.nan), "00:00")
    }

    func testNamedSequenceLibraryRoundTripsStageIDsAndPitchTuning() throws {
        var stage = PsychoacousticProgramStage(durationMinutes: 7, beatHz: 6.5, carrierHz: 440)
        stage.tuning = .equalA440
        stage.noteClass = 9
        stage.octave = 4
        let sequence = SavedPsychoacousticSequence(
            id: UUID(), name: "Original hour session", stages: [stage]
        )
        let data = try JSONEncoder().encode([sequence])
        let restored = try JSONDecoder().decode([SavedPsychoacousticSequence].self, from: data)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, sequence.id)
        XCTAssertEqual(restored[0].stages[0].id, stage.id)
        XCTAssertEqual(restored[0].stages[0].tuning, .equalA440)
        XCTAssertEqual(restored[0].stages[0].beatHz, 6.5, accuracy: 0.000001)
        XCTAssertEqual(restored[0].name, sequence.name)
    }

    func test432AndCustomA4ReferenceUseEqualTemperament() {
        XCTAssertEqual(CarrierPitchTuning.equalA440.frequency(noteClass: 9, octave: 4)!,
                       440, accuracy: 0.000001)
        XCTAssertEqual(CarrierPitchTuning.equalA432.frequency(noteClass: 9, octave: 4)!,
                       432, accuracy: 0.000001)
        XCTAssertEqual(CarrierPitchTuning.equalA432.frequency(noteClass: 11, octave: 4)!,
                       432 * pow(2.0, 2.0 / 12.0), accuracy: 0.000001)
        XCTAssertEqual(CarrierPitchTuning.customA4Reference.frequency(
            noteClass: 9, octave: 4, referenceA4Hz: 444)!, 444, accuracy: 0.000001)
        XCTAssertEqual(CarrierPitchTuning.customA4Reference.frequency(
            noteClass: 11, octave: 4, referenceA4Hz: 444)!,
            444 * pow(2.0, 2.0 / 12.0), accuracy: 0.000001)
        XCTAssertEqual(CarrierPitchTuning.equalA440.frequency(noteClass: 0, octave: 4)!,
                       261.625565, accuracy: 0.00001)
        XCTAssertEqual(CarrierPitchTuning.noteNames[0], "C / B♯")
        XCTAssertEqual(CarrierPitchTuning.noteNames[8], "G♯ / A♭")
        XCTAssertNil(CarrierPitchTuning.equalA440.frequency(noteClass: -1, octave: 4))
        XCTAssertNil(CarrierPitchTuning.equalA440.frequency(noteClass: 0, octave: 6))
        XCTAssertNil(CarrierPitchTuning.manualHz.frequency(noteClass: 9, octave: 4))
        XCTAssertNil(CarrierPitchTuning.customA4Reference.frequency(
            noteClass: 9, octave: 4, referenceA4Hz: .nan))
        XCTAssertFalse(CarrierPitchTuning.allCases.contains { $0.rawValue == "naturalFiveLimitC" })
    }

    func testOctavesOnlyOfferSupportedCarrierRange() {
        var stage = PsychoacousticProgramStage(durationMinutes: 2, beatHz: 6, carrierHz: 440)
        stage.tuning = .equalA432
        XCTAssertFalse(stage.supports(note: 0, octave: 0)) // C0 below human hearing
        XCTAssertFalse(stage.supports(note: 0, octave: 1))
        XCTAssertFalse(stage.supports(note: 0, octave: 2)) // C2 <100Hz engine bound
        XCTAssertTrue(stage.supports(note: 9, octave: 2)) // A2 108Hz
        XCTAssertTrue(stage.supports(note: 0, octave: 3))
        XCTAssertTrue(stage.supports(note: 0, octave: 5))
        XCTAssertFalse(stage.supports(note: 11, octave: 5)) // B5 exceeds 800Hz
        stage.tuning = .customA4Reference
        stage.referenceA4Hz = 512
        XCTAssertEqual(stage.tunedCarrier(for: 9, octave: 4)!, 512,
                       accuracy: 0.000001)
        stage.referenceA4Hz = 0
        XCTAssertFalse(stage.supports(note: 9, octave: 4))
    }

    func testLegacyFiveLimitStageMigratesWithoutPreservingOldTuning() throws {
        var legacy = PsychoacousticProgramStage(durationMinutes: 2, beatHz: 6, carrierHz: 264)
        legacy.tuning = .equalA440
        legacy.noteClass = 0
        legacy.octave = 4
        let original = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        let changed = original.replacingOccurrences(of: "equalA440", with: "naturalFiveLimitC")
        let restored = try JSONDecoder().decode(
            PsychoacousticProgramStage.self, from: Data(changed.utf8))
        XCTAssertEqual(restored.tuning, .equalA432)
        XCTAssertEqual(restored.carrierHz,
                       CarrierPitchTuning.equalA432.frequency(noteClass: 0, octave: 4)!,
                       accuracy: 0.000001)
        XCTAssertEqual(restored.referenceA4Hz, 432, accuracy: 0.000001)
    }

    func testPsychoacousticPresetJSONExcludesVideoAndMetronomeState() throws {
        let stages = [PsychoacousticProgramStage(durationMinutes: 5, beatHz: 6,
                                                  carrierHz: 244)]
        let settings = PsychoacousticSoundSettings(
            carrierHz: 244, beatHz: 6, gain: 0.2, modeRaw: "binaural",
            whiteNoise: 0.02, pinkNoise: 0.05, brownNoise: 0,
            sessionMinutes: 5, customSessionSeconds: nil, fadeDurationSeconds: 20,
            selectedProgramRaw: "steadySix", stages: stages
        )
        XCTAssertTrue(settings.isValid)
        let preset = PsychoacousticSoundPreset(id: UUID(), name: "Evening focus",
                                                settings: settings)
        let json = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(PsychoacousticSoundPreset.self, from: json)
        XCTAssertEqual(decoded.name, "Evening focus")
        XCTAssertEqual(decoded.settings.carrierHz, 244, accuracy: 0.000001)
        XCTAssertEqual(decoded.settings.pinkNoise, 0.05, accuracy: 0.000001)
        XCTAssertEqual(decoded.settings.fadeDurationSeconds, 20)
        XCTAssertTrue(decoded.settings.isValid)
        let encodedText = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(encodedText.contains("metronome"))
        XCTAssertFalse(encodedText.contains("AVPlayer"))
        XCTAssertFalse(encodedText.contains("video"))
    }

    func testStageTimelineSupportsAnyPracticalStageCountAndHourLongDurations() {
        let stages = (0..<101).map { index in
            PsychoacousticProgramStage(durationMinutes: 1, beatHz: Double(index % 20 + 2),
                                       carrierHz: 220 + Double(index % 5) * 30)
        }
        let timeline = PsychoacousticStageTimeline(stages: stages)
        XCTAssertTrue(timeline.isValid)
        XCTAssertEqual(timeline.durationSeconds, 6_060)
        XCTAssertEqual(timeline.carriers(elapsed: 6059)!.beat, 2, accuracy: 0.000001)
        let distributed = timeline.distributedEvenly(over: 7_374)!
        XCTAssertEqual(distributed.count, 101)
        XCTAssertEqual(distributed.reduce(0) { $0 + $1.durationSeconds }, 7_374)
        XCTAssertEqual(distributed[0].durationSeconds, 74)
        XCTAssertEqual(distributed[99].durationSeconds, 73)
        XCTAssertTrue(PsychoacousticStageTimeline(stages: distributed).isValid)
        XCTAssertNil(timeline.distributedEvenly(over: 100))
        XCTAssertFalse(PsychoacousticStageTimeline(stages: []).isValid)
    }

    func testStageTimelineGlidesBothCarrierAndDifferenceWithoutDiscontinuity() {
        let first = PsychoacousticProgramStage(durationMinutes: 1, beatHz: 6, carrierHz: 440)
        let next = PsychoacousticProgramStage(durationMinutes: 1, beatHz: 10, carrierHz: 350)
        let timeline = PsychoacousticStageTimeline(stages: [first, next])
        XCTAssertTrue(timeline.isValid)
        let before = timeline.carriers(elapsed: 50)!
        let middle = timeline.carriers(elapsed: 55)!
        let after = timeline.carriers(elapsed: 60)!
        XCTAssertEqual(before.left, 440, accuracy: 0.00001)
        XCTAssertEqual(before.beat, 6, accuracy: 0.00001)
        XCTAssertEqual(middle.left, 395, accuracy: 0.00001)
        XCTAssertEqual(middle.beat, 8, accuracy: 0.00001)
        XCTAssertEqual(middle.right, 403, accuracy: 0.00001)
        XCTAssertEqual(after.left, 350, accuracy: 0.00001)
        XCTAssertEqual(after.beat, 10, accuracy: 0.00001)
        let a = timeline.carriers(elapsed: 59.999)!
        let b = timeline.carriers(elapsed: 60)!
        XCTAssertLessThan(abs(a.left - b.left), 0.001)
        XCTAssertLessThan(abs(a.beat - b.beat), 0.001)
    }

    func testStageTimelineRejectsUnsafeAndOverflowingPlans() {
        var bad = PsychoacousticProgramStage(durationMinutes: 1, beatHz: 6, carrierHz: 440)
        bad.durationSeconds = 9
        XCTAssertFalse(PsychoacousticStageTimeline(stages: [bad]).isValid)
        bad.durationSeconds = 60
        bad.carrierHz = 900
        XCTAssertFalse(PsychoacousticStageTimeline(stages: [bad]).isValid)
        bad.carrierHz = 800
        bad.beatHz = 41
        XCTAssertFalse(PsychoacousticStageTimeline(stages: [bad]).isValid)
        let enormous = PsychoacousticProgramStage(durationMinutes: 1, beatHz: 6, carrierHz: 440)
        var one = enormous
        one.durationSeconds = Int.max - 15
        XCTAssertFalse(PsychoacousticStageTimeline(stages: [one, enormous]).isValid)
    }

    func testEditableStageTimelineTransitionsAndValidation() {
        let stages = [
            PsychoacousticProgramStage(durationMinutes: 1, beatHz: 10),
            PsychoacousticProgramStage(durationMinutes: 2, beatHz: 8),
            PsychoacousticProgramStage(durationMinutes: 1, beatHz: 6)
        ]
        let timeline = PsychoacousticStageTimeline(stages: stages)
        XCTAssertTrue(timeline.isValid)
        XCTAssertEqual(timeline.totalSeconds, 240)
        XCTAssertEqual(timeline.carriers(elapsed: 0)!.beat, 10, accuracy: 0.000001)
        XCTAssertEqual(timeline.carriers(elapsed: 50)!.beat, 10, accuracy: 0.000001)
        XCTAssertEqual(timeline.carriers(elapsed: 55)!.beat, 9, accuracy: 0.000001)
        XCTAssertEqual(timeline.carriers(elapsed: 60)!.beat, 8, accuracy: 0.000001)
        XCTAssertEqual(timeline.carriers(elapsed: 175)!.beat, 7, accuracy: 0.000001)
        XCTAssertEqual(timeline.carriers(elapsed: 240)!.beat, 6, accuracy: 0.000001)
        XCTAssertNil(timeline.carriers(elapsed: .nan))
        XCTAssertFalse(PsychoacousticStageTimeline(stages: []).isValid)
        XCTAssertFalse(PsychoacousticStageTimeline(stages: [
            PsychoacousticProgramStage(durationMinutes: 2, beatHz: 50)
        ]).isValid)
        var prior = 10.0
        for sample in 0...2400 {
            let current = timeline.carriers(elapsed: Double(sample)/10)!.beat
            XCTAssertLessThanOrEqual(current, prior + 0.0000001)
            prior = current
        }
    }

    func testThreeStageTimelineFrequencyAndSmoothBoundaries() {
        let arc = ExperimentalListeningProgram.threeStageArc
        XCTAssertEqual(arc.carriers(progress: 0).beat, 10, accuracy: 0.0001)
        XCTAssertEqual(arc.carriers(progress: 0.2).beat, 10, accuracy: 0.0001)
        XCTAssertEqual(arc.carriers(progress: 0.4).beat, 8, accuracy: 0.0001)
        XCTAssertEqual(arc.carriers(progress: 0.6).beat, 8, accuracy: 0.0001)
        XCTAssertEqual(arc.carriers(progress: 0.8).beat, 6, accuracy: 0.0001)
        XCTAssertEqual(arc.carriers(progress: 1).beat, 6, accuracy: 0.0001)
        var previous = 10.0
        for i in 0...3000 {
            let setting = arc.carriers(progress: Double(i) / 3000)
            XCTAssertLessThanOrEqual(setting.beat, previous + 0.000001)
            XCTAssertEqual(setting.left + setting.beat, setting.right, accuracy: 0.000001)
            previous = setting.beat
        }
    }

    func testExperimentalProgramCarriersContinuousAndBounded() {
        let steady = ExperimentalListeningProgram.steadySix
        XCTAssertEqual(steady.carriers(progress: 0).beat, 6)
        XCTAssertEqual(steady.carriers(progress: 0.5).beat, 6)
        let glide = ExperimentalListeningProgram.tenToSixGlide
        XCTAssertEqual(glide.carriers(progress: 0).beat, 10)
        XCTAssertEqual(glide.carriers(progress: 0.5).beat, 8, accuracy: 0.00001)
        XCTAssertEqual(glide.carriers(progress: 1).beat, 6)
        var prev = 10.0
        for i in 0...1000 {
            let c = glide.carriers(progress: Double(i) / 1000)
            XCTAssertEqual(c.right, 250, accuracy: 0.0000001)
            XCTAssertLessThanOrEqual(c.beat, prev + 0.0000001)
            prev = c.beat
        }
        XCTAssertEqual(glide.carriers(progress: .nan).beat, 10)
        XCTAssertEqual(glide.carriers(progress: 2).beat, 6)
    }

    func testVideoBoostAppliesMakeupToQuietAudioAndBoundsPeaks() {
        var quiet = Array(repeating: Float(0.1), count: 4_800)
        VideoAudioBoostPolicy.process(&quiet)
        XCTAssertEqual(quiet.last!, 0.19952623, accuracy: 0.003)
        var loud = Array(repeating: Float(0.8), count: 4_800)
        VideoAudioBoostPolicy.process(&loud)
        XCTAssertTrue(loud.allSatisfy { $0.isFinite && abs($0) <= VideoAudioBoostPolicy.ceiling })
        XCTAssertLessThan(loud.last!, 0.8) // sustained peaks compress
        XCTAssertGreaterThan(loud.last!, 0.25) // not muted by dynamics
    }

    func testVideoDynamicsLinksStereoAndRecoversAfterLoudSignal() {
        var dynamics = VideoAudioDynamics(sampleRate: 48_000)
        var left = Float.zero
        var right = Float.zero
        for _ in 0..<4_800 {
            let sameGain = dynamics.outputGain(forInputPeak: 0.8, makeup: 1.9952623)
            left = 0.8 * sameGain
            right = -0.4 * sameGain
            XCTAssertLessThanOrEqual(abs(left), VideoAudioBoostPolicy.ceiling)
            XCTAssertEqual(right / left, -0.5, accuracy: 0.0001)
        }
        let compressed = abs(left)
        var recovered: Float = 0
        for _ in 0..<48_000 {
            recovered = 0.1 * dynamics.outputGain(forInputPeak: 0.1, makeup: 1.9952623)
        }
        XCTAssertGreaterThan(recovered, 0.18)
        XCTAssertLessThan(compressed, VideoAudioBoostPolicy.ceiling)
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
    var hasStereoHeadphoneOutput = true
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
