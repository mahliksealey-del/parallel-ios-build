import Combine
import Foundation
import PsychoacousticDSP

/// App-level fifth transport. The three AVPlayers and metronome remain
/// independent AudioSessionCoordinator sources.
@MainActor
final class PsychoacousticViewModel: ObservableObject, AudioPlaybackSource {
    enum Preset: String, CaseIterable { case focus, calm, rest }
    @Published var carrierHz: Double = 200
    @Published var beatHz: Double = 10
    @Published var gain: Double = PsychoacousticGainPolicy.defaultLevel
    @Published var mode: PsychoacousticMode = .binaural
    @Published var whiteNoise = 0.0
    @Published var pinkNoise = 0.0
    @Published var brownNoise = 0.0
    @Published var sessionMinutes = 0
    @Published var fadeDurationSeconds = 10
    @Published private(set) var selectedProgram: ExperimentalListeningProgram?
    @Published private(set) var programCurrentBeatHz: Double?
    @Published private(set) var editableStages = [
        PsychoacousticProgramStage(durationMinutes: 2, beatHz: 10),
        PsychoacousticProgramStage(durationMinutes: 2, beatHz: 8),
        PsychoacousticProgramStage(durationMinutes: 1, beatHz: 6)
    ]
    @Published private(set) var isPlaying = false
    @Published private(set) var remainingSeconds: TimeInterval?
    @Published private(set) var fadeRemainingSeconds: TimeInterval?
    @Published private(set) var errorMessage: String?

    /// A conventional EEG frequency-band *label* for the stimulus difference,
    /// not a claim that the listener's EEG follows this frequency.
    static func bandLabel(for beatHz: Double) -> String {
        guard beatHz.isFinite, beatHz > 0 else { return "Not classified" }
        switch beatHz {
        case ..<4: return "Delta-range"
        case ..<8: return "Theta-range"
        case ..<13: return "Alpha-range"
        case ..<30: return "Beta-range"
        default: return "Gamma-range"
        }
    }

    var bandLabel: String { Self.bandLabel(for: programCurrentBeatHz ?? beatHz) }

    private weak var session: AudioSessionCoordinator?
    private let graph: AudioGraphCoordinator
    private let sourceID = AudioSourceID.psychoacoustic
    private var stopTask: Task<Void, Never>?
    private var mixerLevel = 1.0

    init(graph: AudioGraphCoordinator, coordinator: AudioSessionCoordinator) {
        self.graph = graph
        self.session = coordinator
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "psycho.carrier") != nil {
            carrierHz = min(800, max(100, defaults.double(forKey: "psycho.carrier")))
            beatHz = min(40, max(1, defaults.double(forKey: "psycho.beat")))
            gain = min(PsychoacousticGainPolicy.maximum,
                       max(0, defaults.double(forKey: "psycho.gain")))
            if let raw = defaults.string(forKey: "psycho.mode"),
               let savedMode = PsychoacousticMode(rawValue: raw) { mode = savedMode }
            whiteNoise = min(0.2, max(0, defaults.double(forKey: "psycho.white")))
            pinkNoise = min(0.2, max(0, defaults.double(forKey: "psycho.pink")))
            brownNoise = min(0.2, max(0, defaults.double(forKey: "psycho.brown")))
        }
        let savedFade = defaults.integer(forKey: "psycho.fadeDuration")
        if [5, 10, 20, 30].contains(savedFade) {
            fadeDurationSeconds = savedFade
        }
        precondition(coordinator.register(self, for: sourceID),
                     "Psychoacoustic source was already registered.")
    }

    func togglePlayback() {
        guard let session else { return }
        errorMessage = nil
        if session.requestedSources.contains(sourceID) {
            session.stopPlayback(for: sourceID)
        } else {
            session.requestPlayback(for: sourceID)
        }
        isPlaying = session.requestedSources.contains(sourceID)
                   && session.state == .active
        // start(sampleRate:) owns session timing; a failed start never arms a clock.
        if !isPlaying { cancelSessionClock() }
    }

    func applyFrequencies() {
        // Program selection updates displayed carrier values; only the explicit
        // Clear Program or a preset change disengages the selected sequence.
        guard parametersAreValid else {
            errorMessage = PsychoacousticAudioError.invalidParameters.localizedDescription
            return
        }
        guard isPlaying else { return }
        if graph.updatePsychoacousticFrequencies(
            left: carrierHz, right: carrierHz + beatHz
        ) {
            errorMessage = nil
            persist()
        } else {
            errorMessage = PsychoacousticAudioError.controlQueueFull.localizedDescription
        }
    }

    func applyGain() {
        guard parametersAreValid else {
            errorMessage = PsychoacousticAudioError.invalidParameters.localizedDescription
            return
        }
        guard isPlaying else { return }
        if graph.updatePsychoacousticGain(gain) {
            errorMessage = nil
            persist()
        } else {
            errorMessage = PsychoacousticAudioError.controlQueueFull.localizedDescription
        }
    }

    func applyLayers() {
        guard layerParametersAreValid else {
            errorMessage = "Noise levels must be between 0 and 20%."
            return
        }
        guard isPlaying else { return }
        let modeOK = graph.updatePsychoacousticMode(mode)
        let noiseOK = graph.updatePsychoacousticNoise(noiseLevels)
        errorMessage = modeOK && noiseOK ? nil
            : PsychoacousticAudioError.controlQueueFull.localizedDescription
        if modeOK && noiseOK { persist() }
    }

    func applyPreset(_ preset: Preset) {
        selectedProgram = nil
        programCurrentBeatHz = nil
        switch preset {
        case .focus: carrierHz = 220; beatHz = 14; mode = .binaural; pinkNoise = 0.04
        case .calm: carrierHz = 180; beatHz = 8; mode = .monaural; pinkNoise = 0.08
        case .rest: carrierHz = 140; beatHz = 4; mode = .isochronic; brownNoise = 0.08
        }
        applyFrequencies()
        applyLayers()
        persist()
    }

    func applySessionTimer() {
        // A custom duration deliberately exits the fixed 5-minute acoustic
        // comparison rather than claiming the source study used other timing.
        if let program = selectedProgram {
            let expectedMinutes = program == .threeStageArc
                ? editableStages.reduce(0) { $0 + $1.durationMinutes }
                : 5
            if sessionMinutes != expectedMinutes {
                selectedProgram = nil
                programCurrentBeatHz = nil
            }
        }
        if isPlaying { scheduleStopIfNeeded() }
    }

    func applyFadeDuration() {
        guard [5, 10, 20, 30].contains(fadeDurationSeconds) else {
            fadeDurationSeconds = 10
            return
        }
        UserDefaults.standard.set(fadeDurationSeconds, forKey: "psycho.fadeDuration")
        // The existing uptime deadline remains intact; only the ending
        // envelope length changes. No restart or surprise auto-play.
    }

    func updateProgramStage(index: Int, durationMinutes: Int? = nil, beatHz: Double? = nil) {
        guard !isPlaying, editableStages.indices.contains(index) else { return }
        var revised = editableStages
        if let durationMinutes { revised[index].durationMinutes = durationMinutes }
        if let beatHz { revised[index].beatHz = beatHz }
        guard PsychoacousticStageTimeline(stages: revised).isValid else { return }
        editableStages = revised
        if selectedProgram == .threeStageArc {
            sessionMinutes = revised.reduce(0) { $0 + $1.durationMinutes }
            self.beatHz = revised[0].beatHz
            carrierHz = 250 - revised[0].beatHz
        }
    }

    func chooseExperimentalProgram(_ program: ExperimentalListeningProgram?) {
        guard !isPlaying else {
            errorMessage = "Stop generated audio before changing listening programs."
            return
        }
        selectedProgram = program
        programCurrentBeatHz = nil
        if let program {
            if program == .threeStageArc {
                guard PsychoacousticStageTimeline(stages: editableStages).isValid else {
                    selectedProgram = nil
                    errorMessage = "Invalid acoustic stage configuration."
                    return
                }
                sessionMinutes = editableStages.reduce(0) { $0 + $1.durationMinutes }
                beatHz = editableStages[0].beatHz
                carrierHz = 250 - beatHz
            } else {
                sessionMinutes = 5
                carrierHz = program.initialLeftHz
                beatHz = program.initialBeatHz
            }
            mode = .binaural
            // No extra noise confound in these original comparison scenes.
            whiteNoise = 0
            pinkNoise = 0
            brownNoise = 0
        } else {
            // Avoid retaining an unsupported Picker tag from a custom duration.
            sessionMinutes = 5
        }
        errorMessage = nil
        persist()
    }

    /// Controls the composite stereo-generated bus, preserving the internal
    /// tone + three noise layers and combining with the session end envelope.
    func setMixerLevel(_ value: Double) {
        guard value.isFinite, (0...1).contains(value) else { return }
        mixerLevel = value
        let fade = fadeRemainingSeconds.map {
            Double(PsychoacousticSessionEnvelope.gain(
                remaining: $0, fadeSeconds: TimeInterval(fadeDurationSeconds)
            ))
        } ?? 1
        if isPlaying { _ = graph.updatePsychoacousticOutputVolume(value * fade) }
    }

    func reportError(_ message: String) {
        cancelSessionClock()
        errorMessage = message
        isPlaying = false
    }

    func start(sampleRate: Double) throws {
        guard parametersAreValid else { throw PsychoacousticAudioError.invalidParameters }
        guard PsychoacousticOutputPolicy.stereoHeadphonesAvailable() else {
            throw PsychoacousticAudioError.headphonesRequired
        }
        try graph.startPsychoacoustic(
            sampleRate: sampleRate,
            leftHz: carrierHz,
            rightHz: carrierHz + beatHz,
            gain: gain, mode: mode, noise: noiseLevels
        )
        isPlaying = true
        errorMessage = nil
        scheduleStopIfNeeded()
    }

    func stop() {
        cancelSessionClock()
        graph.stopPsychoacoustic()
        isPlaying = false
    }

    func markInterrupted() { stop() }

    func markRecovering() { stop() }

    private var parametersAreValid: Bool {
        carrierHz.isFinite && (100...800).contains(carrierHz)
        && beatHz.isFinite && (1...40).contains(beatHz)
        && gain.isFinite && (0...PsychoacousticGainPolicy.maximum).contains(gain)
        && layerParametersAreValid
    }

    private var layerParametersAreValid: Bool {
        [whiteNoise, pinkNoise, brownNoise].allSatisfy {
            $0.isFinite && (0...0.2).contains($0)
        }
    }

    private var noiseLevels: NoiseLevels {
        .init(white: whiteNoise, pink: pinkNoise, brown: brownNoise)
    }

    private func cancelSessionClock() {
        stopTask?.cancel()
        stopTask = nil
        remainingSeconds = nil
        fadeRemainingSeconds = nil
        programCurrentBeatHz = nil
    }

    private func scheduleStopIfNeeded() {
        cancelSessionClock()
        // The psycho source owns this node. Do not affect the metronome/video paths.
        _ = graph.updatePsychoacousticOutputVolume(mixerLevel)
        guard isPlaying, sessionMinutes > 0 else { return }

        // Monotonic deadline avoids cumulative Task.sleep drift and re-syncs
        // the visible countdown after a period with no foreground UI updates.
        // Changing duration intentionally starts a fresh interval, as before.
        let duration = TimeInterval(sessionMinutes * 60)
        let startUptime = ProcessInfo.processInfo.systemUptime
        remainingSeconds = duration
        stopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.isPlaying else { return }
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startUptime)
                let remaining = PsychoacousticSessionEnvelope.remaining(
                    elapsed: elapsed, duration: duration)
                self.remainingSeconds = remaining
                // Original, deterministic glide uses the renderer's existing
                // phase-continuous frequency ramp, not restarted oscillators.
                if let program = self.selectedProgram {
                    let settings: (left: Double, right: Double, beat: Double)
                    if program == .threeStageArc {
                        let timeline = PsychoacousticStageTimeline(stages: self.editableStages)
                        guard let stageSettings = timeline.carriers(elapsed: elapsed) else {
                            self.errorMessage = "Invalid acoustic stage configuration."
                            self.session?.stopPlayback(for: self.sourceID)
                            return
                        }
                        settings = stageSettings
                    } else {
                        settings = program.carriers(progress: elapsed / duration)
                    }
                    self.programCurrentBeatHz = settings.beat
                    if program != .steadySix && remaining > 0 {
                        guard self.graph.updatePsychoacousticFrequencies(
                            left: settings.left, right: settings.right
                        ) else {
                            self.errorMessage = "Program transition could not be queued."
                            self.session?.stopPlayback(for: self.sourceID)
                            return
                        }
                    }
                }
                if remaining <= 0 {
                    _ = self.graph.updatePsychoacousticOutputVolume(0)
                    self.session?.stopPlayback(for: self.sourceID)
                    return
                }
                if remaining <= TimeInterval(self.fadeDurationSeconds) {
                    self.fadeRemainingSeconds = remaining
                    _ = self.graph.updatePsychoacousticOutputVolume(
                        self.mixerLevel * Double(PsychoacousticSessionEnvelope.gain(
                            remaining: remaining,
                            fadeSeconds: TimeInterval(self.fadeDurationSeconds)
                        )))
                } else {
                    self.fadeRemainingSeconds = nil
                }
                // Control-rate envelope for this initial prototype. True
                // sample-accurate fading and background tails need device tests.
                do {
                    try await Task.sleep(nanoseconds:
                        remaining <= TimeInterval(self.fadeDurationSeconds)
                        ? 50_000_000 : 250_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(carrierHz, forKey: "psycho.carrier")
        defaults.set(beatHz, forKey: "psycho.beat")
        defaults.set(gain, forKey: "psycho.gain")
        defaults.set(mode.rawValue, forKey: "psycho.mode")
        defaults.set(whiteNoise, forKey: "psycho.white")
        defaults.set(pinkNoise, forKey: "psycho.pink")
        defaults.set(brownNoise, forKey: "psycho.brown")
    }
}


/// Original deterministic raised-cosine control envelope. It attenuates the
/// existing psychoacoustic mixer (tone + all noise layers) as one composite.
/// It is not a claim of sample-accurate multi-AVPlayer synchronization.
enum PsychoacousticSessionEnvelope {
    static let fadeSeconds: TimeInterval = 10

    static func remaining(elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        max(0, duration - max(0, elapsed))
    }

    static func gain(remaining: TimeInterval, fadeSeconds duration: TimeInterval = 10) -> Float {
        guard duration.isFinite, duration > 0 else { return 0 }
        let remaining = remaining.isFinite ? remaining : 0
        let u = 1 - min(1, max(0, remaining / duration))
        return Float(0.5 * (1 + cos(.pi * u)))
    }
}


/// Original acoustic controls only: exact output frequencies are specified;
/// no EEG state, cognitive change or clinical effect is inferred.
/// The steady 6 Hz choice is an **acoustic comparison**, not a claim that the
/// 2026 PLOS ONE self-report results replicate on this user's device.
enum ExperimentalListeningProgram: String, CaseIterable {
    case steadySix
    case tenToSixGlide
    case threeStageArc

    var label: String {
        switch self {
        case .steadySix: return "Steady 6 Hz (5 min)"
        case .tenToSixGlide: return "Original 10 → 6 Hz glide (5 min)"
        case .threeStageArc: return "Editable three-stage sequence"
        }
    }

    var initialLeftHz: Double {
        switch self {
        case .steadySix: return 244
        case .tenToSixGlide, .threeStageArc: return 240
        }
    }
    var initialBeatHz: Double {
        switch self {
        case .steadySix: return 6
        case .tenToSixGlide, .threeStageArc: return 10
        }
    }

    func carriers(progress: Double) -> (left: Double, right: Double, beat: Double) {
        let u = progress.isFinite ? min(1, max(0, progress)) : 0
        let ease = u * u * (3 - 2 * u)
        let beat: Double
        switch self {
        case .steadySix:
            beat = 6
        case .tenToSixGlide:
            beat = 10 - 4 * ease
        case .threeStageArc:
            // Stage 1 (0–2m): 10Hz, last 10s glide to 8Hz.
            // Stage 2 (2–4m): 8Hz, last 10s glide to 6Hz.
            // Stage 3 (4–5m): 6Hz steady. Clock uses normalized 5m.
            let boundary1 = 120.0 / 300
            let boundary2 = 240.0 / 300
            let transitionLength = 10.0 / 300
            if u < boundary1 - transitionLength {
                beat = 10
            } else if u < boundary1 {
                let t = (u - (boundary1 - transitionLength)) / transitionLength
                let smooth = t * t * (3 - 2 * t)
                beat = 10 - 2 * smooth
            } else if u < boundary2 - transitionLength {
                beat = 8
            } else if u < boundary2 {
                let t = (u - (boundary2 - transitionLength)) / transitionLength
                let smooth = t * t * (3 - 2 * t)
                beat = 8 - 2 * smooth
            } else {
                beat = 6
            }
        }
        return (250 - beat, 250, beat)
    }
}


/// A completely local sequence definition. Each stage holds its stimulus
/// difference until its final transition window, glides to the next stage
/// without phase reset, and never reaches into video or external-app output.
struct PsychoacousticProgramStage: Equatable {
    var durationMinutes: Int
    var beatHz: Double
}

struct PsychoacousticStageTimeline {
    let stages: [PsychoacousticProgramStage]
    let transitionSeconds: Double = 10

    var isValid: Bool {
        (1...6).contains(stages.count)
        && stages.allSatisfy {
            (1...10).contains($0.durationMinutes)
            && $0.beatHz.isFinite && (1...40).contains($0.beatHz)
        }
        && stages.reduce(0) { $0 + $1.durationMinutes } <= 30
    }

    var totalSeconds: TimeInterval {
        stages.reduce(0) { $0 + TimeInterval($1.durationMinutes) * 60 }
    }

    func carriers(elapsed: TimeInterval) -> (left: Double, right: Double, beat: Double)? {
        guard isValid, elapsed.isFinite else { return nil }
        let clamped = min(max(0, elapsed), totalSeconds)
        var offset: TimeInterval = 0
        for index in stages.indices {
            let stage = stages[index]
            let stageEnd = offset + TimeInterval(stage.durationMinutes) * 60
            if clamped < stageEnd || index == stages.count - 1 {
                var difference = stage.beatHz
                if index + 1 < stages.count {
                    let rampStart = stageEnd - transitionSeconds
                    if clamped >= rampStart {
                        let u = min(1, max(0, (clamped - rampStart) / transitionSeconds))
                        let smooth = u * u * (3 - 2 * u)
                        difference += (stages[index + 1].beatHz - difference) * smooth
                    }
                }
                // Fixed right carrier, left carrier varies 210...249 Hz.
                return (250 - difference, 250, difference)
            }
            offset = stageEnd
        }
        return nil
    }
}
