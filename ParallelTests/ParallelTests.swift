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

    func testVideoBoostAppliesSixDecibelsAndLimitsPeaks() {
        var samples: [Float] = [0, 0.1, -0.25, 0.6, -1]
        VideoAudioBoostPolicy.process(&samples)
        XCTAssertEqual(samples[0], 0, accuracy: 0.000001)
        XCTAssertEqual(samples[1], 0.19952623, accuracy: 0.000001)
        XCTAssertEqual(samples[2], -0.49881557, accuracy: 0.000001)
        XCTAssertEqual(samples[3], 0.98, accuracy: 0.000001)
        XCTAssertEqual(samples[4], -0.98, accuracy: 0.000001)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.98 })
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
