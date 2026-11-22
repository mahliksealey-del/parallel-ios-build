import Foundation

public enum MetronomeTimingError: Error, Equatable {
    case invalidBPM
    case invalidSampleRate
}

public struct BeatFrameScheduler: Equatable {
    public static let bpmRange = 30.0...300.0
    public let bpm: Double
    public let sampleRate: Double
    private let framesPerBeat: Double
    private var accumulatedFrame = 0.0
    private var emittedFrame: Int64 = 0

    public init(bpm: Double, sampleRate: Double) throws {
        guard bpm.isFinite, Self.bpmRange.contains(bpm) else { throw MetronomeTimingError.invalidBPM }
        guard sampleRate.isFinite, sampleRate > 0 else { throw MetronomeTimingError.invalidSampleRate }
        self.bpm = bpm
        self.sampleRate = sampleRate
        self.framesPerBeat = sampleRate * 60.0 / bpm
    }

    public var beatDuration: TimeInterval { 60.0 / bpm }

    public mutating func nextIntervalFrames() -> Int64 {
        accumulatedFrame += framesPerBeat
        let nextFrame = Int64(accumulatedFrame.rounded())
        let interval = nextFrame - emittedFrame
        emittedFrame = nextFrame
        return interval
    }

    public var cumulativeIdealFrame: Double { accumulatedFrame }
    public var cumulativeEmittedFrame: Int64 { emittedFrame }
}

public struct AccentSequence: Equatable {
    public let beatsPerBar: Int
    private(set) public var beatIndex = 0

    public init(beatsPerBar: Int = 4) {
        precondition(beatsPerBar > 0)
        self.beatsPerBar = beatsPerBar
    }

    public mutating func nextIsAccent() -> Bool {
        let isAccent = beatIndex == 0
        beatIndex = (beatIndex + 1) % beatsPerBar
        return isAccent
    }
}


// Phase 4. Wall-clock time is an absolute reference; musical meter, inhale/
// exhale and optional cross-rhythm are phases of the same timeline. This
// Foundation-only model can be tested without AVAudioEngine or a physical phone.
public enum CrossRhythmMode: String, Codable, CaseIterable {
    case off, grouped, ratio
}

public enum MinuteBlockAnchor: String, Codable, CaseIterable {
    case clock, session
}

public struct ClockRhythmSettings: Codable, Equatable {
    public var clockSync = false
    public var meterNumerator = 4
    public var meterDenominator = 4
    public var inhaleCounts = 4
    public var exhaleCounts = 8
    /// A breathing count normally equals one quarter note.
    public var countDenominator = 4
    public var markerEnabled = true
    public var markerVolume = 0.55
    public var markerVariant = 0
    public var breathCues = false
    public var supercycleCues = false
    public var crossMode: CrossRhythmMode = .off
    public var crossGroup = 3
    public var ratioPulses = 3
    public var ratioDuration = 4
    public var groupingMinutes = 5
    public var blockAnchor: MinuteBlockAnchor = .clock
    public var resetBreathingOnMinute = false
    public var showUTC = false
    public var advancedView = false
    public var sessionStartUnixSeconds: Double? = nil

    public init() {}

    public var isValid: Bool {
        (1...32).contains(meterNumerator)
            && [1, 2, 4, 8, 16, 32].contains(meterDenominator)
            && (1...256).contains(inhaleCounts) && (1...256).contains(exhaleCounts)
            && [1, 2, 4, 8, 16, 32].contains(countDenominator)
            && markerVolume.isFinite && (0...1).contains(markerVolume)
            && (0...2).contains(markerVariant)
            && (2...64).contains(crossGroup)
            && (2...16).contains(ratioPulses)
            && (2...32).contains(ratioDuration)
            && [5, 15, 30, 60].contains(groupingMinutes)
            && (sessionStartUnixSeconds == nil || sessionStartUnixSeconds!.isFinite)
    }
}

public struct RhythmPosition: Equatable {
    public let measure: Int64
    public let beatInMeasure: Double
    public let breathGroup: Int64
    public let breathCountInGroup: Double
    public let exhaling: Bool
    public let nextBarInSeconds: Double
    public let nextBreathInSeconds: Double
}

public struct MinuteRhythmAnalysis {
    public let beatsPerMinute: Double
    public let fullMeasures: Int64
    public let remainingMeterBeats: Double
    public let fullBreathingGroups: Int64
    public let remainingBreathCounts: Double
    public let breathingSeconds: Double
    /// At a common :00 starting origin. The live current-minute phase is
    /// separately obtained using position(atUnixSeconds:).
    public let nextMinutePosition: RhythmPosition
    public let supercycleBeats: Double?
    public let masterAlignmentMinutes: Int64?
}

public enum ClockRhythmMath {
    /// Use 32 ticks per quarter note: exact for common denominators 1..32.
    public static let ticksPerQuarter: Int64 = 32

    public static func positiveRemainder(_ x: Double, _ m: Double) -> Double {
        guard x.isFinite, m.isFinite, m > 0 else { return 0 }
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }

    public static func minuteClock(at unixSeconds: Double) -> (elapsed: Double, untilNext: Double) {
        let elapsed = positiveRemainder(unixSeconds, 60)
        return (elapsed, 60 - elapsed)
    }

    public static func position(atUnixSeconds t: Double, bpm: Double,
                                settings: ClockRhythmSettings) -> RhythmPosition? {
        guard settings.isValid, bpm.isFinite, BeatFrameScheduler.bpmRange.contains(bpm),
              t.isFinite else { return nil }
        let unitQuarter = 4.0 / Double(settings.meterDenominator)
        let meterQuarter = Double(settings.meterNumerator) * unitQuarter
        let breathingCountQuarter = 4.0 / Double(settings.countDenominator)
        let inhaleQuarter = Double(settings.inhaleCounts) * breathingCountQuarter
        let breathQuarter = Double(settings.inhaleCounts + settings.exhaleCounts) * breathingCountQuarter
        let musicalQuarter = t * bpm / 60.0
        let measureIndex = floor(musicalQuarter / meterQuarter)
        let groupQuarter = settings.resetBreathingOnMinute
            ? minuteClock(at: t).elapsed * bpm / 60.0
            : musicalQuarter
        let groupIndex = floor(groupQuarter / breathQuarter)
        guard measureIndex >= Double(Int64.min), measureIndex < Double(Int64.max),
              groupIndex >= Double(Int64.min), groupIndex < Double(Int64.max) else { return nil }
        let inBar = positiveRemainder(musicalQuarter, meterQuarter)
        let inBreath = positiveRemainder(groupQuarter, breathQuarter)
        let remainingBar = meterQuarter - inBar
        let remainingBreath = breathQuarter - inBreath
        return RhythmPosition(
            measure: Int64(measureIndex), beatInMeasure: inBar / unitQuarter + 1,
            breathGroup: Int64(groupIndex),
            breathCountInGroup: inBreath / breathingCountQuarter + 1,
            exhaling: inBreath >= inhaleQuarter,
            nextBarInSeconds: remainingBar * 60 / bpm,
            nextBreathInSeconds: remainingBreath * 60 / bpm
        )
    }

    public static func analyze(bpm: Double, settings: ClockRhythmSettings,
                               forecastMinutes: Int64 = 1_440) -> MinuteRhythmAnalysis? {
        guard settings.isValid, bpm.isFinite, BeatFrameScheduler.bpmRange.contains(bpm) else {
            return nil
        }
        let musicalCountsPerMinute = bpm * Double(settings.meterDenominator) / 4
        let countPerMinute = bpm * Double(settings.countDenominator) / 4
        let breathLength = Double(settings.inhaleCounts + settings.exhaleCounts)
        let measures = floor(musicalCountsPerMinute / Double(settings.meterNumerator))
        let groups = floor(countPerMinute / breathLength)
        guard measures < Double(Int64.max), groups < Double(Int64.max),
              let boundary = position(atUnixSeconds: 60, bpm: bpm, settings: settings) else {
            return nil
        }
        let cycleTicks = cycleLengthTicks(settings: settings)
        let bpmMilli = Int64((bpm * 1_000).rounded())
        var alignment: Int64?
        if let cycleTicks, let modulus = multiplied(cycleTicks, 1_000),
           let num = multiplied(bpmMilli, ticksPerQuarter), num > 0 {
            let cycleMinutes = modulus / gcd(modulus, num)
            if cycleMinutes > 0 && cycleMinutes <= forecastMinutes {
                alignment = cycleMinutes
            }
        }
        return MinuteRhythmAnalysis(
            beatsPerMinute: musicalCountsPerMinute,
            fullMeasures: Int64(measures),
            remainingMeterBeats: musicalCountsPerMinute - measures * Double(settings.meterNumerator),
            fullBreathingGroups: Int64(groups),
            remainingBreathCounts: countPerMinute - groups * breathLength,
            breathingSeconds: breathLength * 60 / countPerMinute,
            nextMinutePosition: boundary,
            supercycleBeats: cycleTicks.map { Double($0) / Double(ticksPerQuarter) },
            masterAlignmentMinutes: alignment
        )
    }

    private static func multiplied(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }

    public static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    public static func lcm(_ a: Int64, _ b: Int64) -> Int64? {
        guard a > 0 && b > 0 else { return nil }
        return multiplied(a / gcd(a, b), b)
    }

    /// Periodic accent structure, excluding ratio subdivisions because the
    /// ratio pattern itself repeats after its containing duration.
    public static func cycleLengthTicks(settings: ClockRhythmSettings) -> Int64? {
        guard settings.isValid else { return nil }
        let bar = Int64(settings.meterNumerator) * 4 * ticksPerQuarter
                  / Int64(settings.meterDenominator)
        let breath = Int64(settings.inhaleCounts + settings.exhaleCounts) * 4
                     * ticksPerQuarter / Int64(settings.countDenominator)
        guard let combined = lcm(bar, breath) else { return nil }
        switch settings.crossMode {
        case .off: return combined
        case .grouped:
            return lcm(combined, Int64(settings.crossGroup) * ticksPerQuarter)
        case .ratio:
            return lcm(combined, Int64(settings.ratioDuration) * ticksPerQuarter)
        }
    }

    /// Beat index for a grid with no Start-button reset. Returning nil for
    /// negative or nonfinite time prevents spurious click attacks.
    public static func eventIndex(atUnixSeconds t: Double, period: Double) -> Int64? {
        guard t.isFinite, period.isFinite, period > 0 else { return nil }
        let result = floor(t / period)
        guard result >= Double(Int64.min), result < Double(Int64.max) else { return nil }
        return Int64(result)
    }

    public static func meterBeatDescription(_ beat: Double) -> String {
        guard beat.isFinite && beat >= 1 else { return "Unavailable" }
        let whole = Int(floor(beat))
        let fraction = beat - Double(whole)
        if fraction < 0.005 { return "Beat \(whole)" }
        if abs(fraction - 0.5) < 0.005 { return "Upbeat after beat \(whole)" }
        if abs(fraction - 0.25) < 0.005 { return "Quarter subdivision after beat \(whole)" }
        if abs(fraction - 0.75) < 0.005 { return "Three-quarter subdivision after beat \(whole)" }
        return String(format: "Between beats \(whole) and \(whole + 1) (%.2f)", fraction)
    }

    /// Positive displacement to the first *future* exact master alignment
    /// assuming a common :00 origin and constant tempo.
    public static func nextAlignment(after unixSeconds: Double,
                                     alignmentMinutes: Int64) -> Double? {
        guard unixSeconds.isFinite, alignmentMinutes > 0 else { return nil }
        let seconds = Double(alignmentMinutes) * 60
        let elapsed = positiveRemainder(unixSeconds, seconds)
        return seconds - elapsed
    }
}
