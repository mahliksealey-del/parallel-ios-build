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

    func testClock60BPMFourFourAndFourEightBreathing() throws {
        let settings = ClockRhythmSettings()
        let one = try XCTUnwrap(ClockRhythmMath.analyze(bpm: 60, settings: settings))
        XCTAssertEqual(one.beatsPerMinute, 60, accuracy: 0.000001)
        XCTAssertEqual(one.fullMeasures, 15)
        XCTAssertEqual(one.remainingMeterBeats, 0, accuracy: 0.000001)
        XCTAssertEqual(one.fullBreathingGroups, 5)
        XCTAssertEqual(one.remainingBreathCounts, 0, accuracy: 0.000001)
        XCTAssertEqual(one.breathingSeconds, 12, accuracy: 0.000001)
        XCTAssertEqual(one.nextMinutePosition.beatInMeasure, 1, accuracy: 0.000001)
        XCTAssertEqual(one.masterAlignmentMinutes, 1)
    }

    func testClock90BPMFourFourSevenAndHalfBreathsTwoMinuteAlignment() throws {
        let settings = ClockRhythmSettings()
        let one = try XCTUnwrap(ClockRhythmMath.analyze(bpm: 90, settings: settings))
        XCTAssertEqual(one.beatsPerMinute, 90, accuracy: 0.000001)
        XCTAssertEqual(one.fullMeasures, 22)
        XCTAssertEqual(one.remainingMeterBeats, 2, accuracy: 0.000001)
        XCTAssertEqual(one.fullBreathingGroups, 7)
        XCTAssertEqual(one.remainingBreathCounts, 6, accuracy: 0.000001)
        XCTAssertEqual(one.nextMinutePosition.beatInMeasure, 3, accuracy: 0.000001)
        XCTAssertEqual(one.nextMinutePosition.breathCountInGroup, 7, accuracy: 0.000001)
        XCTAssertTrue(one.nextMinutePosition.exhaling)
        XCTAssertEqual(one.masterAlignmentMinutes, 2)
    }

    func testSevenFourAt60BPMAndFourEightBreathingAlignsEverySevenMinutes() throws {
        var settings = ClockRhythmSettings()
        settings.meterNumerator = 7
        let one = try XCTUnwrap(ClockRhythmMath.analyze(bpm: 60, settings: settings))
        XCTAssertEqual(one.fullMeasures, 8)
        XCTAssertEqual(one.remainingMeterBeats, 4, accuracy: 0.000001)
        XCTAssertEqual(one.fullBreathingGroups, 5)
        XCTAssertEqual(one.nextMinutePosition.beatInMeasure, 5, accuracy: 0.000001)
        XCTAssertEqual(one.masterAlignmentMinutes, 7)
    }

    func testFractional82Point5BPMKeepsSubdivisionsAndExactRecurrence() throws {
        let settings = ClockRhythmSettings()
        let one = try XCTUnwrap(ClockRhythmMath.analyze(bpm: 82.5, settings: settings))
        XCTAssertEqual(one.fullMeasures, 20)
        XCTAssertEqual(one.remainingMeterBeats, 2.5, accuracy: 0.000001)
        XCTAssertEqual(one.fullBreathingGroups, 6)
        XCTAssertEqual(one.remainingBreathCounts, 10.5, accuracy: 0.000001)
        XCTAssertEqual(one.nextMinutePosition.beatInMeasure, 3.5, accuracy: 0.000001)
        XCTAssertEqual(ClockRhythmMath.meterBeatDescription(3.5), "Upbeat after beat 3")
        XCTAssertEqual(one.masterAlignmentMinutes, 8)
    }

    func testSevenEightAt120WithThreeBeatCrossingAlignsSevenMinutes() throws {
        var settings = ClockRhythmSettings()
        settings.meterNumerator = 7
        settings.meterDenominator = 8
        settings.crossMode = .grouped
        settings.crossGroup = 3
        let one = try XCTUnwrap(ClockRhythmMath.analyze(bpm: 120, settings: settings))
        XCTAssertEqual(one.supercycleBeats!, 84, accuracy: 0.000001)
        XCTAssertEqual(one.masterAlignmentMinutes, 7)
        XCTAssertEqual(one.beatsPerMinute, 240, accuracy: 0.000001)
    }

    func testOptionalThreeVsFourGroupingMeetsEveryTwelveQuarterBeats() throws {
        var settings = ClockRhythmSettings()
        settings.crossMode = .grouped
        settings.crossGroup = 3
        XCTAssertEqual(ClockRhythmMath.cycleLengthTicks(settings: settings), 384)
        XCTAssertEqual(ClockRhythmMath.analyze(bpm: 90, settings: settings)!
                       .supercycleBeats!, 12, accuracy: 0.000001)
    }

    func testMidMinuteJoinReferencesRealClockNotStart() throws {
        let settings = ClockRhythmSettings()
        let time = 37.250
        let position = try XCTUnwrap(ClockRhythmMath.position(
            atUnixSeconds: time, bpm: 60, settings: settings))
        XCTAssertEqual(position.beatInMeasure, 2.25, accuracy: 0.000001)
        let remaining = ClockRhythmMath.minuteClock(at: time)
        XCTAssertEqual(remaining.elapsed, 37.250, accuracy: 0.000001)
        XCTAssertEqual(remaining.untilNext, 22.750, accuracy: 0.000001)
        XCTAssertEqual(ClockRhythmMath.eventIndex(atUnixSeconds: time, period: 1), 37)
        XCTAssertEqual(ClockRhythmMath.eventIndex(atUnixSeconds: 38, period: 1), 38)
    }

    func testMinuteBreathingGroupTwoOfFiveAndBarFourOfFifteen() throws {
        let s = ClockRhythmSettings()
        let progress = try XCTUnwrap(ClockRhythmMath.minuteWindow(
            atUnixSeconds: 73.1, bpm: 60, settings: s))
        XCTAssertEqual(progress.groupNumber, 2)
        XCTAssertEqual(progress.totalGroups, 5)
        XCTAssertEqual(progress.measureNumber, 4)
        XCTAssertEqual(progress.totalMeasures, 15)
        XCTAssertEqual(progress.elapsedSeconds, 13.1, accuracy: 0.00001)
        XCTAssertEqual(progress.secondsRemaining, 46.9, accuracy: 0.00001)
    }

    func testPartialBreathingGroupsRemainCountedInsideEachMinute() throws {
        let s = ClockRhythmSettings()
        let firstMinute = try XCTUnwrap(ClockRhythmMath.minuteWindow(
            atUnixSeconds: 9, bpm: 90, settings: s))
        XCTAssertEqual(firstMinute.groupNumber, 2)
        XCTAssertEqual(firstMinute.totalGroups, 8) // 7 complete + 1 partial
        XCTAssertEqual(firstMinute.totalMeasures, 23) // 22 complete + partial
        let nextMinute = try XCTUnwrap(ClockRhythmMath.minuteWindow(
            atUnixSeconds: 65, bpm: 90, settings: s))
        XCTAssertEqual(nextMinute.groupNumber, 2)
        XCTAssertEqual(nextMinute.totalGroups, 8) // both edge groups partial
        XCTAssertEqual(nextMinute.measureNumber, 3)
    }

    func testLongUnixEpochCannotLeakHugeBreathingOrMeasureNumbers() throws {
        let s = ClockRhythmSettings()
        let farFuture: Double = 1_798_000_000.0
        let value = try XCTUnwrap(ClockRhythmMath.minuteWindow(
            atUnixSeconds: farFuture, bpm: 180, settings: s))
        XCTAssertTrue((1...16).contains(value.groupNumber))
        XCTAssertTrue((1...16).contains(value.totalGroups))
        XCTAssertTrue((1...46).contains(value.measureNumber))
        XCTAssertTrue((1...46).contains(value.totalMeasures))
    }

    func testMinuteResetMakesGroupsLocalWithoutResettingMeter() throws {
        var s = ClockRhythmSettings()
        s.resetBreathingOnMinute = true
        let value = try XCTUnwrap(ClockRhythmMath.minuteWindow(
            atUnixSeconds: 69, bpm: 90, settings: s))
        XCTAssertEqual(value.groupNumber, 2)
        XCTAssertEqual(value.totalGroups, 8)
        XCTAssertEqual(value.measureNumber, 4)
    }

    func testMusicalAlignmentNeverTriggersLongTimeChunkGO() {
        var s = ClockRhythmSettings()
        s.supercycleCues = true // the previously saved higher-timeframe toggle
        s.alignmentCueEnabled = true

        let eachMinute = ClockRhythmMath.cueEvents(
            minuteCrossed: true, minuteIndex: 121,
            chunkCrossed: false, settings: s, fullAlignmentMinutes: 1)
        XCTAssertTrue(eachMinute.minuteTick)
        XCTAssertTrue(eachMinute.musicalAlignmentPing)
        XCTAssertFalse(eachMinute.timeChunkGO) // Crucial user-requested separation

        let fiveMinuteChunk = ClockRhythmMath.cueEvents(
            minuteCrossed: true, minuteIndex: 125,
            chunkCrossed: true, settings: s, fullAlignmentMinutes: 1)
        XCTAssertTrue(fiveMinuteChunk.minuteTick)
        XCTAssertFalse(fiveMinuteChunk.musicalAlignmentPing) // less sound clutter
        XCTAssertTrue(fiveMinuteChunk.timeChunkGO)

        s.markerEnabled = false
        let goOnly = ClockRhythmMath.cueEvents(
            minuteCrossed: false, minuteIndex: 125,
            chunkCrossed: true, settings: s, fullAlignmentMinutes: 1)
        XCTAssertFalse(goOnly.minuteTick)
        XCTAssertFalse(goOnly.musicalAlignmentPing)
        XCTAssertTrue(goOnly.timeChunkGO)

        s.supercycleCues = false
        let alignmentOnly = ClockRhythmMath.cueEvents(
            minuteCrossed: true, minuteIndex: 126,
            chunkCrossed: true, settings: s, fullAlignmentMinutes: 1)
        XCTAssertFalse(alignmentOnly.minuteTick)
        XCTAssertTrue(alignmentOnly.musicalAlignmentPing)
        XCTAssertFalse(alignmentOnly.timeChunkGO)
    }

    func testDefaultAudioAvoidsExtraMusicalAlignmentNoise() {
        let s = ClockRhythmSettings()
        XCTAssertFalse(s.playsAlignmentCue)
        let atClock = ClockRhythmMath.cueEvents(
            minuteCrossed: true, minuteIndex: 100,
            chunkCrossed: false, settings: s, fullAlignmentMinutes: 1)
        XCTAssertTrue(atClock.minuteTick)
        XCTAssertFalse(atClock.musicalAlignmentPing)
        XCTAssertFalse(atClock.timeChunkGO)
    }

    func testTimeChunkFiveTenFifteenAndCustomMinuteBoundaries() throws {
        var s = ClockRhythmSettings()
        for minutes in [5, 10, 15, 30, 60, 7, 11, 120, 1_440] {
            s.groupingMinutes = minutes
            XCTAssertTrue(s.isValid)
            let boundary = Double(minutes) * 60
            let before = try XCTUnwrap(ClockRhythmMath.chunkIndex(
                atUnixSeconds: boundary - 0.001, settings: s))
            let after = try XCTUnwrap(ClockRhythmMath.chunkIndex(
                atUnixSeconds: boundary, settings: s))
            XCTAssertEqual(before, 0, "Unexpected early GO for \(minutes) minutes")
            XCTAssertEqual(after, 1, "No GO at \(minutes) minutes")
            XCTAssertEqual(ClockRhythmMath.chunkIndex(
                atUnixSeconds: boundary * 2, settings: s), 2)
        }
        s.groupingMinutes = 0
        XCTAssertFalse(s.isValid)
        s.groupingMinutes = 1_441
        XCTAssertFalse(s.isValid)
    }

    func testCustomChunkCanBeAnchoredToSessionInsteadOfUtcMinute() throws {
        var s = ClockRhythmSettings()
        s.groupingMinutes = 10
        s.blockAnchor = .session
        s.sessionStartUnixSeconds = 137.5
        XCTAssertEqual(ClockRhythmMath.chunkIndex(
            atUnixSeconds: 737.499, settings: s), 0)
        XCTAssertEqual(ClockRhythmMath.chunkIndex(
            atUnixSeconds: 737.5, settings: s), 1)
        s.blockAnchor = .clock
        XCTAssertEqual(ClockRhythmMath.chunkIndex(
            atUnixSeconds: 599.9, settings: s), 0)
        XCTAssertEqual(ClockRhythmMath.chunkIndex(
            atUnixSeconds: 600, settings: s), 1)
        XCTAssertEqual(ClockRhythmMath.chunkIndex(
            atUnixSeconds: 1_200, settings: s), 2)
    }

    func testExistingD01ClockSettingsAndPresetsRemainCodable() throws {
        // New settings are optional, so decode older D01 JSON *without*
        // the new keys and preserve the owner's prior cue and volume values.
        var previous = ClockRhythmSettings()
        previous.supercycleCues = true
        previous.groupCueVolume = 0.43
        previous.groupingMinutes = 15
        let original = try JSONEncoder().encode(previous)
        let json = String(decoding: original, as: UTF8.self)
        XCTAssertFalse(json.contains("alignmentCueEnabled"))
        XCTAssertFalse(json.contains("alignmentCueVolume"))
        let restored = try JSONDecoder().decode(ClockRhythmSettings.self, from: original)
        XCTAssertTrue(restored.supercycleCues)
        XCTAssertFalse(restored.playsAlignmentCue)
        XCTAssertEqual(restored.groupCueVolume, 0.43, accuracy: 0.000001)
        XCTAssertEqual(restored.groupingMinutes, 15)

        previous.alignmentCueEnabled = true
        previous.alignmentCueVolume = 0.18
        previous.groupingMinutes = 7
        let edited = try JSONDecoder().decode(
            ClockRhythmSettings.self, from: JSONEncoder().encode(previous))
        XCTAssertTrue(edited.playsAlignmentCue)
        XCTAssertEqual(edited.effectiveAlignmentCueVolume, 0.18, accuracy: 0.000001)
        XCTAssertEqual(edited.groupingMinutes, 7)
    }

    func testMinuteBoundaryLatchNeverDuplicatesClicks() {
        var latch = ClockBoundaryLatch()
        XCTAssertFalse(latch.advance(to: 100))
        XCTAssertFalse(latch.advance(to: 100))
        XCTAssertFalse(latch.advance(to: 100))
        XCTAssertTrue(latch.advance(to: 101))
        XCTAssertFalse(latch.advance(to: 101))
        XCTAssertFalse(latch.advance(to: 103)) // Missing minute: no late burst
        XCTAssertTrue(latch.advance(to: 104))
        XCTAssertFalse(latch.advance(to: 100))
        XCTAssertTrue(latch.advance(to: 101))
        var sentinel = ClockBoundaryLatch()
        XCTAssertFalse(sentinel.advance(to: Int64.max))
        XCTAssertFalse(sentinel.advance(to: Int64.max))
    }

    func testMinuteBoundaryCrossingExactly59ToZero() {
        let before = ClockRhythmMath.minuteClock(at: 59.999)
        let after = ClockRhythmMath.minuteClock(at: 60.0)
        XCTAssertEqual(before.elapsed, 59.999, accuracy: 0.000001)
        XCTAssertEqual(before.untilNext, 0.001, accuracy: 0.000001)
        XCTAssertEqual(after.elapsed, 0, accuracy: 0.000001)
        XCTAssertEqual(after.untilNext, 60, accuracy: 0.000001)
        XCTAssertEqual(ClockRhythmMath.eventIndex(atUnixSeconds: 59.999, period: 60), 0)
        XCTAssertEqual(ClockRhythmMath.eventIndex(atUnixSeconds: 60, period: 60), 1)
    }

    func testOddMeterAndBreathUnitAndReset() throws {
        var settings = ClockRhythmSettings()
        settings.meterNumerator = 13
        settings.meterDenominator = 16
        settings.countDenominator = 8
        let a = try XCTUnwrap(ClockRhythmMath.analyze(bpm: 120.5, settings: settings))
        XCTAssertTrue(a.beatsPerMinute > 480)
        XCTAssertTrue(a.breathingSeconds > 0)
        settings.resetBreathingOnMinute = true
        let justAfter = try XCTUnwrap(ClockRhythmMath.position(
            atUnixSeconds: 60.1, bpm: 90, settings: settings))
        XCTAssertEqual(justAfter.breathCountInGroup, 1.3, accuracy: 0.000001)
    }

    func testBreathingResetOnMinuteChangesMasterCycleWithoutChangingMusicalMeter() throws {
        var settings = ClockRhythmSettings()
        settings.meterNumerator = 4
        settings.inhaleCounts = 7
        settings.exhaleCounts = 8
        XCTAssertEqual(ClockRhythmMath.analyze(bpm: 90, settings: settings)?
                       .masterAlignmentMinutes, 2)
        settings.resetBreathingOnMinute = true
        XCTAssertEqual(ClockRhythmMath.analyze(bpm: 90, settings: settings)?
                       .masterAlignmentMinutes, 2)
        let boundary = try XCTUnwrap(ClockRhythmMath.position(
            atUnixSeconds: 60, bpm: 90, settings: settings))
        XCTAssertEqual(boundary.breathCountInGroup, 1, accuracy: 0.000001)
    }

    func testPresentationOnlySettingsDoNotRebuildAudio() {
        var a = ClockRhythmSettings()
        var b = a
        b.advancedView = true
        b.showUTC = true
        XCTAssertTrue(a.hasSameAudioConfiguration(as: b))
        a.crossMode = .grouped
        XCTAssertFalse(a.hasSameAudioConfiguration(as: b))
        a = b
        a.alignmentCueEnabled = true
        XCTAssertFalse(a.hasSameAudioConfiguration(as: b))
        a = b
        a.groupingMinutes = 10
        XCTAssertFalse(a.hasSameAudioConfiguration(as: b))
    }

    func testMetronomePresetsAreIsolatedFromMedia() throws {
        var s = ClockRhythmSettings()
        s.clockSync = true
        s.breathCueVolume = 0.15
        s.groupCueVolume = 0.1
        s.sessionStartUnixSeconds = nil
        let preset = MetronomeClockPreset(id: UUID(), name: "Clock Practice",
                                           bpm: 82.5, settings: s,
                                           gain: 0.7, boostedClicks: true)
        XCTAssertTrue(preset.isValid)
        let data = try JSONEncoder().encode(preset)
        let restored = try JSONDecoder().decode(MetronomeClockPreset.self, from: data)
        XCTAssertEqual(restored.id, preset.id)
        XCTAssertEqual(restored.bpm, 82.5, accuracy: 0.000001)
        XCTAssertEqual(restored.gain, 0.7, accuracy: 0.000001)
        XCTAssertTrue(restored.boostedClicks)
        XCTAssertEqual(restored.settings.breathCueVolume, 0.15, accuracy: 0.000001)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("psychoacoustic"))
        XCTAssertFalse(json.contains("AVPlayer"))
        XCTAssertFalse(json.contains("video"))
    }

    func testForecastLimitsAndSettingsPersistenceRoundTrip() throws {
        var settings = ClockRhythmSettings()
        settings.meterNumerator = 31
        settings.meterDenominator = 32
        settings.inhaleCounts = 47
        settings.exhaleCounts = 83
        settings.crossMode = .grouped
        settings.crossGroup = 17
        settings.clockSync = true
        settings.showUTC = true
        settings.markerVariant = 2
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(ClockRhythmSettings.self, from: data)
        XCTAssertEqual(settings, restored)
        XCTAssertTrue(restored.isValid)
        let limited = try XCTUnwrap(ClockRhythmMath.analyze(
            bpm: 82.125, settings: restored, forecastMinutes: 10))
        XCTAssertNil(limited.masterAlignmentMinutes)
        XCTAssertEqual(ClockRhythmMath.nextAlignment(after: 119, alignmentMinutes: 2)!,
                       1, accuracy: 0.000001)
    }

    func testInvalidSettingsAndNegativeClockTimeDoNotCrash() {
        var settings = ClockRhythmSettings()
        settings.meterDenominator = 3
        XCTAssertFalse(settings.isValid)
        XCTAssertNil(ClockRhythmMath.analyze(bpm: 60, settings: settings))
        settings.meterDenominator = 4
        XCTAssertEqual(ClockRhythmMath.positiveRemainder(-0.5, 60), 59.5,
                       accuracy: 0.000001)
        XCTAssertNil(ClockRhythmMath.eventIndex(atUnixSeconds: .nan, period: 1))
        XCTAssertNil(ClockRhythmMath.eventIndex(atUnixSeconds: 5, period: 0))
        XCTAssertNil(ClockRhythmMath.analyze(bpm: .nan, settings: settings))
        XCTAssertNil(ClockRhythmMath.analyze(bpm: 82.5003, settings: settings)?
                         .masterAlignmentMinutes)
    }

}
