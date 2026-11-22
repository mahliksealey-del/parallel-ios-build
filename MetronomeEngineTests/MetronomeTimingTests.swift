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
    }

}
