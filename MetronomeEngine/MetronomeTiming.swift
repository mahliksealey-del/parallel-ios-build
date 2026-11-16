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
