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
        PsychoacousticProgramStage(durationMinutes: 2, beatHz: 10, carrierHz: 240),
        PsychoacousticProgramStage(durationMinutes: 2, beatHz: 8, carrierHz: 242),
        PsychoacousticProgramStage(durationMinutes: 1, beatHz: 6, carrierHz: 244)
    ]
    @Published private(set) var customSessionSeconds: Int?
    @Published private(set) var savedSequences: [SavedPsychoacousticSequence] = []
    @Published private(set) var soundPresets: [PsychoacousticSoundPreset] = []
    @Published private(set) var selectedSoundPresetID: UUID?
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
        if let data = defaults.data(forKey: "psycho.stages.v2"),
           let saved = try? JSONDecoder().decode([PsychoacousticProgramStage].self, from: data),
           PsychoacousticStageTimeline(stages: saved).isValid {
            editableStages = saved
        }
        if let savedData = defaults.data(forKey: "psycho.sequenceLibrary.v1"),
           let decoded = try? JSONDecoder().decode(
                [SavedPsychoacousticSequence].self, from: savedData) {
            savedSequences = decoded.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                PsychoacousticStageTimeline(stages: $0.stages).isValid
            }
        }
        if let seconds = defaults.object(forKey: "psycho.customDuration.v2") as? Int,
           seconds >= 10 {
            customSessionSeconds = seconds
        }
        let savedFade = defaults.integer(forKey: "psycho.fadeDuration")
        if [5, 10, 20, 30].contains(savedFade) {
            fadeDurationSeconds = savedFade
        }
        if let data = defaults.data(forKey: "psycho.soundPresets.v1"),
           let decoded = try? JSONDecoder().decode([PsychoacousticSoundPreset].self, from: data) {
            soundPresets = decoded.filter { $0.settings.isValid && !$0.name.isEmpty }
        }
        if let data = defaults.data(forKey: "psycho.workingSettings.v1"),
           let settings = try? JSONDecoder().decode(PsychoacousticSoundSettings.self, from: data),
           settings.isValid {
            restoreSoundSettings(settings)
        }
        if let id = defaults.string(forKey: "psycho.selectedSoundPreset.v1")
            .flatMap(UUID.init(uuidString:)),
           soundPresets.contains(where: { $0.id == id }) {
            selectedSoundPresetID = id
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
        guard isPlaying else {
            errorMessage = nil
            persist()
            return
        }
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
        guard isPlaying else {
            errorMessage = nil
            persist()
            return
        }
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
        guard isPlaying else {
            errorMessage = nil
            persist()
            return
        }
        let modeOK = graph.updatePsychoacousticMode(mode)
        let noiseOK = graph.updatePsychoacousticNoise(noiseLevels)
        errorMessage = modeOK && noiseOK ? nil
            : PsychoacousticAudioError.controlQueueFull.localizedDescription
        if modeOK && noiseOK { persist() }
    }

    func applyPreset(_ preset: Preset) {
        selectedProgram = nil
        programCurrentBeatHz = nil
        whiteNoise = 0
        pinkNoise = 0
        brownNoise = 0
        switch preset {
        case .focus: carrierHz = 220; beatHz = 14; mode = .binaural; pinkNoise = 0.04
        case .calm: carrierHz = 180; beatHz = 8; mode = .monaural; pinkNoise = 0.08
        case .rest: carrierHz = 140; beatHz = 4; mode = .isochronic; brownNoise = 0.08
        }
        applyFrequencies()
        applyLayers()
        persist()
    }

    /// Exact session duration, allowing hours rather than only whole minutes.
    /// Previously published research-reference timings are never retimed.
    var configuredSessionSeconds: Int {
        if let program = selectedProgram {
            return program == .threeStageArc
                ? (PsychoacousticStageTimeline(stages: editableStages).durationSeconds ?? 0)
                : 300
        }
        return customSessionSeconds ?? (sessionMinutes * 60)
    }

    func applySessionTimer() {
        guard selectedProgram == nil else { return }
        customSessionSeconds = nil
        UserDefaults.standard.removeObject(forKey: "psycho.customDuration.v2")
        persistWorkingSettings()
        if isPlaying { scheduleStopIfNeeded() }
    }

    func applyFadeDuration() {
        guard [5, 10, 20, 30].contains(fadeDurationSeconds) else {
            fadeDurationSeconds = 10
            return
        }
        UserDefaults.standard.set(fadeDurationSeconds, forKey: "psycho.fadeDuration")
        persistWorkingSettings()
    }

    /// This overload preserves the original UI while the editor is migrated.
    func updateProgramStage(index: Int, durationMinutes: Int? = nil, beatHz: Double? = nil) {
        guard editableStages.indices.contains(index) else { return }
        updateProgramStage(
            id: editableStages[index].id,
            durationSeconds: durationMinutes.map { $0 * 60 }, beatHz: beatHz
        )
    }

    func updateProgramStage(
        id: UUID, durationSeconds: Int? = nil, beatHz: Double? = nil,
        carrierHz: Double? = nil, tuning: CarrierPitchTuning? = nil,
        noteClass: Int? = nil, octave: Int? = nil,
        referenceA4Hz: Double? = nil
    ) {
        guard !isPlaying, let index = editableStages.firstIndex(where: { $0.id == id }) else {
            errorMessage = "Stop psychoacoustic audio to edit a stage."
            return
        }
        var updated = editableStages
        if let durationSeconds { updated[index].durationSeconds = durationSeconds }
        if let beatHz { updated[index].beatHz = beatHz }
        if let tuning { updated[index].tuning = tuning }
        if let noteClass { updated[index].noteClass = noteClass }
        if let octave { updated[index].octave = octave }
        if let referenceA4Hz { updated[index].referenceA4Hz = referenceA4Hz }
        if let carrierHz {
            updated[index].carrierHz = carrierHz
            updated[index].tuning = .manualHz
        } else if updated[index].tuning != .manualHz,
                  let pitch = updated[index].tuning.frequency(
                    noteClass: updated[index].noteClass, octave: updated[index].octave,
                    referenceA4Hz: updated[index].referenceA4Hz) {
            updated[index].carrierHz = pitch
        }
        guard PsychoacousticStageTimeline(stages: updated).isValid else {
            errorMessage = "Outside the audio range: carrier 100–800 Hz, binaural difference 1–40 Hz, A4 reference 200–800 Hz and at least 10 seconds. C0/C1 are not playable in this engine."
            return
        }
        editableStages = updated
        syncFirstStageIfSelected()
        persistEditableStages()
        errorMessage = nil
    }

    func addProgramStage() {
        guard !isPlaying else {
            errorMessage = "Stop psychoacoustic audio to add a stage."
            return
        }
        var next = editableStages.last ??
            PsychoacousticProgramStage(durationMinutes: 5, beatHz: 6, carrierHz: 244)
        next.id = UUID()
        next.durationSeconds = 300
        let revised = editableStages + [next]
        guard PsychoacousticStageTimeline(stages: revised).isValid else {
            errorMessage = "Unable to create another valid stage."
            return
        }
        editableStages = revised
        syncFirstStageIfSelected()
        persistEditableStages()
        errorMessage = nil
    }

    func removeProgramStage(id: UUID) {
        guard !isPlaying, editableStages.count > 1 else { return }
        let revised = editableStages.filter { $0.id != id }
        guard PsychoacousticStageTimeline(stages: revised).isValid else { return }
        editableStages = revised
        syncFirstStageIfSelected()
        persistEditableStages()
        errorMessage = nil
    }

    /// Evenly divides the exact requested total duration over any number
    /// of stages, assigning one extra second to early stages if necessary.
    func setCustomSessionDuration(seconds: Int) {
        guard !isPlaying else {
            errorMessage = "Stop psychoacoustic audio before setting a new duration."
            return
        }
        guard seconds >= 10 else {
            errorMessage = "Custom sessions must be at least 10 seconds."
            return
        }
        if selectedProgram == .threeStageArc {
            guard let distributed = PsychoacousticStageTimeline(stages: editableStages)
                    .distributedEvenly(over: seconds) else {
                errorMessage = "Allocate at least 10 seconds to each stage."
                return
            }
            editableStages = distributed
            syncFirstStageIfSelected()
            persistEditableStages()
            customSessionSeconds = nil
        } else if selectedProgram != nil {
            errorMessage = "The reference listening program keeps its published five-minute timing. Select Editable sequence for custom timing."
            return
        } else {
            customSessionSeconds = seconds
            UserDefaults.standard.set(seconds, forKey: "psycho.customDuration.v2")
        }
        persistWorkingSettings()
        errorMessage = nil
    }

    func chooseExperimentalProgram(_ program: ExperimentalListeningProgram?) {
        guard !isPlaying else {
            errorMessage = "Stop psychoacoustic audio before switching programs."
            return
        }
        if program == .threeStageArc &&
            !PsychoacousticStageTimeline(stages: editableStages).isValid {
            errorMessage = "Check your editable stage settings first."
            return
        }
        selectedProgram = program
        programCurrentBeatHz = nil
        if let program {
            customSessionSeconds = nil
            if program == .threeStageArc {
                sessionMinutes = 5 // display fallback; actual runtime uses stage seconds
                syncFirstStageIfSelected()
            } else {
                sessionMinutes = 5
                carrierHz = program.initialLeftHz
                beatHz = program.initialBeatHz
            }
            mode = .binaural
            whiteNoise = 0
            pinkNoise = 0
            brownNoise = 0
        } else {
            sessionMinutes = 5
        }
        errorMessage = nil
        persist()
    }

    private func syncFirstStageIfSelected() {
        guard selectedProgram == .threeStageArc, let first = editableStages.first else { return }
        carrierHz = first.carrierHz
        beatHz = first.beatHz
    }

    /// Saves user-authored sequences separately from published reference programs.
    /// No app-imposed number of sequences; device storage is finite.
    func saveCustomSequence(name: String) {
        guard !isPlaying, selectedProgram == .threeStageArc else {
            errorMessage = "Select Editable sequence and stop audio before saving."
            return
        }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty,
              PsychoacousticStageTimeline(stages: editableStages).isValid else {
            errorMessage = "Name the sequence and check its stage settings."
            return
        }
        savedSequences.append(SavedPsychoacousticSequence(
            id: UUID(), name: trimmed, stages: editableStages))
        persistSequenceLibrary()
        errorMessage = nil
    }

    func loadCustomSequence(id: UUID) {
        guard !isPlaying, let saved = savedSequences.first(where: { $0.id == id }),
              PsychoacousticStageTimeline(stages: saved.stages).isValid else { return }
        editableStages = saved.stages
        selectedProgram = .threeStageArc
        customSessionSeconds = nil
        mode = .binaural
        syncFirstStageIfSelected()
        persistEditableStages()
        errorMessage = nil
    }

    func deleteCustomSequence(id: UUID) {
        guard !isPlaying else { return }
        savedSequences.removeAll { $0.id == id }
        persistSequenceLibrary()
    }

    private func persistSequenceLibrary() {
        if let data = try? JSONEncoder().encode(savedSequences) {
            UserDefaults.standard.set(data, forKey: "psycho.sequenceLibrary.v1")
        }
    }

    private func persistEditableStages() {
        if let data = try? JSONEncoder().encode(editableStages) {
            UserDefaults.standard.set(data, forKey: "psycho.stages.v2")
        }
        persistWorkingSettings()
    }

    /// A psychoacoustic preset stores only the generated engine's parameters:
    /// never video files/AVPlayer levels or metronome settings.
    private var currentSoundSettings: PsychoacousticSoundSettings {
        PsychoacousticSoundSettings(
            carrierHz: carrierHz, beatHz: beatHz, gain: gain, modeRaw: mode.rawValue,
            whiteNoise: whiteNoise, pinkNoise: pinkNoise, brownNoise: brownNoise,
            sessionMinutes: sessionMinutes, customSessionSeconds: customSessionSeconds,
            fadeDurationSeconds: fadeDurationSeconds,
            selectedProgramRaw: selectedProgram?.rawValue, stages: editableStages
        )
    }

    func saveSoundPreset(name: String) {
        guard !isPlaying else {
            errorMessage = "Stop psychoacoustic playback before saving a preset."
            return
        }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let settings = currentSoundSettings
        guard !trimmed.isEmpty, settings.isValid else {
            errorMessage = "Name your psychoacoustic preset and check its sound parameters."
            return
        }
        let record = PsychoacousticSoundPreset(id: UUID(), name: trimmed, settings: settings)
        soundPresets.append(record)
        selectedSoundPresetID = record.id
        persistSoundPresetLibrary()
        persistWorkingSettings()
        errorMessage = nil
    }

    func loadSoundPreset(id: UUID) {
        guard !isPlaying else {
            errorMessage = "Stop psychoacoustic playback before loading a preset."
            return
        }
        guard let preset = soundPresets.first(where: { $0.id == id }),
              preset.settings.isValid else {
            errorMessage = "This preset is invalid or was deleted."
            return
        }
        restoreSoundSettings(preset.settings)
        selectedSoundPresetID = id
        persistSoundPresetLibrary()
        persistWorkingSettings()
        errorMessage = nil
    }

    func updateSoundPreset(id: UUID) {
        guard !isPlaying,
              let index = soundPresets.firstIndex(where: { $0.id == id }),
              currentSoundSettings.isValid else {
            errorMessage = "Stop audio and select a valid preset to update."
            return
        }
        soundPresets[index] = PsychoacousticSoundPreset(
            id: id, name: soundPresets[index].name, settings: currentSoundSettings)
        selectedSoundPresetID = id
        persistSoundPresetLibrary()
        persistWorkingSettings()
        errorMessage = nil
    }

    func deleteSoundPreset(id: UUID) {
        guard !isPlaying else { return }
        soundPresets.removeAll { $0.id == id }
        if selectedSoundPresetID == id { selectedSoundPresetID = nil }
        persistSoundPresetLibrary()
    }

    private func restoreSoundSettings(_ settings: PsychoacousticSoundSettings) {
        guard settings.isValid, let restoredMode = PsychoacousticMode(rawValue: settings.modeRaw)
        else { return }
        carrierHz = settings.carrierHz
        beatHz = settings.beatHz
        gain = settings.gain
        mode = restoredMode
        whiteNoise = settings.whiteNoise
        pinkNoise = settings.pinkNoise
        brownNoise = settings.brownNoise
        sessionMinutes = settings.sessionMinutes
        customSessionSeconds = settings.customSessionSeconds
        fadeDurationSeconds = settings.fadeDurationSeconds
        editableStages = settings.stages
        selectedProgram = settings.selectedProgramRaw.flatMap(ExperimentalListeningProgram.init(rawValue:))
        // Study-reference choices are always restored to their exact original
        // frequencies, even if a corrupt saved setting supplied other values.
        if let program = selectedProgram, program != .threeStageArc {
            carrierHz = program.initialLeftHz
            beatHz = program.initialBeatHz
            mode = .binaural
            sessionMinutes = 5
            customSessionSeconds = nil
        } else if selectedProgram == .threeStageArc {
            syncFirstStageIfSelected()
            mode = .binaural
            customSessionSeconds = nil
        }
        programCurrentBeatHz = nil
    }

    private func persistSoundPresetLibrary() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(soundPresets) {
            defaults.set(data, forKey: "psycho.soundPresets.v1")
        }
        if let id = selectedSoundPresetID {
            defaults.set(id.uuidString, forKey: "psycho.selectedSoundPreset.v1")
        } else {
            defaults.removeObject(forKey: "psycho.selectedSoundPreset.v1")
        }
    }

    private func persistWorkingSettings() {
        let current = currentSoundSettings
        guard current.isValid, let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: "psycho.workingSettings.v1")
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
        guard PsychoacousticOutputPolicy.supportedExternalOutput() else {
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
        guard isPlaying, configuredSessionSeconds > 0 else { return }

        // Monotonic deadline avoids cumulative Task.sleep drift and re-syncs
        // the visible countdown after a period with no foreground UI updates.
        // Changing duration intentionally starts a fresh interval, as before.
        let duration = TimeInterval(configuredSessionSeconds)
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
        persistWorkingSettings()
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
        case .threeStageArc: return "Editable custom sequence"
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


/// A binaural beat is the left/right difference, independent of the
/// equal-temperament reference for the *audible carrier* notes.
/// 432 Hz means A4=432 Hz, not a distinct "natural" temperament.
/// Legacy five-limit data is migrated to A432 on decode, without keeping a
/// misleading "natural" tuning option in the app.
enum CarrierPitchTuning: String, CaseIterable, Codable {
    case manualHz
    case equalA440
    case equalA432
    case customA4Reference

    var label: String {
        switch self {
        case .manualHz: return "Direct carrier Hz"
        case .equalA440: return "12-TET · A4 = 440 Hz"
        case .equalA432: return "12-TET · A4 = 432 Hz"
        case .customA4Reference: return "12-TET · Custom A4 reference"
        }
    }

    static let noteNames = [
        "C / B♯", "C♯ / D♭", "D", "D♯ / E♭", "E / F♭", "F / E♯",
        "F♯ / G♭", "G", "G♯ / A♭", "A", "A♯ / B♭", "B / C♭"
    ]

    /// Fixed twelve-tone equal temperament, shifted by the selected A4
    /// reference; e.g. B4 at A432 = 432 × 2^(2/12) ≈ 484.99 Hz.
    func frequency(noteClass: Int, octave: Int,
                   referenceA4Hz: Double = 440) -> Double? {
        guard (0..<12).contains(noteClass), (0...5).contains(octave) else { return nil }
        let reference: Double
        switch self {
        case .manualHz: return nil
        case .equalA440: reference = 440
        case .equalA432: reference = 432
        case .customA4Reference:
            guard referenceA4Hz.isFinite, (200...800).contains(referenceA4Hz) else {
                return nil
            }
            reference = referenceA4Hz
        }
        let semitones = 12 * (octave - 4) + noteClass - 9
        return reference * pow(2.0, Double(semitones) / 12.0)
    }

    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        // User's prior five-limit setting is no longer presented. Preserve
        // compatibility with existing stored sequences while converting.
        self = name == "naturalFiveLimitC" ? .equalA432 :
            (CarrierPitchTuning(rawValue: name) ?? .manualHz)
    }
}

struct PsychoacousticProgramStage: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var durationSeconds: Int
    var beatHz: Double
    var carrierHz: Double
    var tuning: CarrierPitchTuning = .manualHz
    var noteClass: Int = 9
    var octave: Int = 3
    var referenceA4Hz: Double = 432

    init(durationMinutes: Int, beatHz: Double, carrierHz: Double = 240) {
        durationSeconds = durationMinutes * 60
        self.beatHz = beatHz
        self.carrierHz = carrierHz
    }

    var durationMinutes: Int {
        get { durationSeconds / 60 }
        set { durationSeconds = newValue * 60 }
    }

    func tunedCarrier(for note: Int, octave requestedOctave: Int) -> Double? {
        tuning.frequency(noteClass: note, octave: requestedOctave,
                         referenceA4Hz: referenceA4Hz)
    }

    /// Notes below 100 Hz (including C0 and C1) or above 800 Hz cannot be
    /// played by this validated renderer; show them disabled, not silently
    /// clamp to another pitch. C2–C5 are partially available.
    func supports(note: Int, octave: Int) -> Bool {
        guard let hz = tunedCarrier(for: note, octave: octave) else { return false }
        return (100...800).contains(hz) && hz + beatHz <= 840
    }

    private enum CodingKeys: String, CodingKey {
        case id, durationSeconds, beatHz, carrierHz, tuning, noteClass, octave, referenceA4Hz
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        durationSeconds = try values.decode(Int.self, forKey: .durationSeconds)
        beatHz = try values.decode(Double.self, forKey: .beatHz)
        carrierHz = try values.decode(Double.self, forKey: .carrierHz)
        let legacyRaw = try values.decodeIfPresent(String.self, forKey: .tuning)
        tuning = (legacyRaw == "naturalFiveLimitC" ? .equalA432 :
            (legacyRaw.flatMap(CarrierPitchTuning.init(rawValue:)) ?? .manualHz))
        noteClass = try values.decodeIfPresent(Int.self, forKey: .noteClass) ?? 9
        octave = try values.decodeIfPresent(Int.self, forKey: .octave) ?? 3
        referenceA4Hz = try values.decodeIfPresent(Double.self, forKey: .referenceA4Hz) ?? 432
        // Convert removed 5-limit saved notes to 432 equal-temperament,
        // rather than labeling the old 5-limit pitch as 432.
        if legacyRaw == "naturalFiveLimitC",
           let newHz = tuning.frequency(noteClass: noteClass, octave: octave) {
            if (100...800).contains(newHz), newHz + beatHz <= 840 {
                carrierHz = newHz
            } else {
                tuning = .manualHz
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(durationSeconds, forKey: .durationSeconds)
        try values.encode(beatHz, forKey: .beatHz)
        try values.encode(carrierHz, forKey: .carrierHz)
        try values.encode(tuning, forKey: .tuning)
        try values.encode(noteClass, forKey: .noteClass)
        try values.encode(octave, forKey: .octave)
        try values.encode(referenceA4Hz, forKey: .referenceA4Hz)
    }
}

struct PsychoacousticStageTimeline {
    let stages: [PsychoacousticProgramStage]
    let transitionSeconds: Double = 10

    /// Computed safely; impossible/overflowing plans are rejected.
    var durationSeconds: Int? {
        guard !stages.isEmpty else { return nil }
        var total = 0
        for stage in stages {
            guard stage.durationSeconds >= 10, stage.beatHz.isFinite,
                  (1...40).contains(stage.beatHz),
                  stage.carrierHz.isFinite, (100...800).contains(stage.carrierHz),
                  stage.carrierHz + stage.beatHz <= 840,
                  (0..<12).contains(stage.noteClass), (0...5).contains(stage.octave),
                  stage.referenceA4Hz.isFinite,
                  (200...800).contains(stage.referenceA4Hz) else {
                return nil
            }
            let (sum, overflow) = total.addingReportingOverflow(stage.durationSeconds)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    var isValid: Bool { durationSeconds != nil }
    var totalSeconds: TimeInterval { TimeInterval(durationSeconds ?? 0) }

    /// Redistribute a user-selected duration as evenly as whole seconds
    /// allow. Remainder goes to the earliest stages deterministically.
    func distributedEvenly(over seconds: Int) -> [PsychoacousticProgramStage]? {
        guard isValid, seconds > 0, seconds / stages.count >= 10 else { return nil }
        let perStage = seconds / stages.count
        let remainder = seconds % stages.count
        return stages.enumerated().map { index, original in
            var stage = original
            stage.durationSeconds = perStage + (index < remainder ? 1 : 0)
            return stage
        }
    }

    func carriers(elapsed: TimeInterval) -> (left: Double, right: Double, beat: Double)? {
        guard let durationSeconds, elapsed.isFinite else { return nil }
        let clamped = min(max(0, elapsed), Double(durationSeconds))
        var offset = 0.0
        for index in stages.indices {
            let stage = stages[index]
            let end = offset + Double(stage.durationSeconds)
            if clamped < end || index == stages.count - 1 {
                var left = stage.carrierHz
                var beat = stage.beatHz
                if index + 1 < stages.count {
                    let rampLength = min(transitionSeconds, Double(stage.durationSeconds) / 2)
                    let rampStart = end - rampLength
                    if clamped >= rampStart {
                        let u = min(1, max(0, (clamped - rampStart) / rampLength))
                        let smooth = u * u * (3 - 2 * u)
                        let next = stages[index + 1]
                        left += (next.carrierHz - left) * smooth
                        beat += (next.beatHz - beat) * smooth
                    }
                }
                return (left, left + beat, beat)
            }
            offset = end
        }
        return nil
    }
}

struct SavedPsychoacousticSequence: Codable, Identifiable {
    let id: UUID
    let name: String
    let stages: [PsychoacousticProgramStage]
}

/// JSON snapshot of the psychoacoustic engine only.
/// Sound presets never include video or metronome state, and loading them
/// deliberately does not auto-play audio.
struct PsychoacousticSoundSettings: Codable {
    let carrierHz: Double
    let beatHz: Double
    let gain: Double
    let modeRaw: String
    let whiteNoise: Double
    let pinkNoise: Double
    let brownNoise: Double
    let sessionMinutes: Int
    let customSessionSeconds: Int?
    let fadeDurationSeconds: Int
    let selectedProgramRaw: String?
    let stages: [PsychoacousticProgramStage]

    var isValid: Bool {
        // Keep the closure outside guard's comma-separated condition list.
        let noiseValid = [whiteNoise, pinkNoise, brownNoise].allSatisfy {
            $0.isFinite && (0...0.2).contains($0)
        }
        guard carrierHz.isFinite, (100...800).contains(carrierHz),
              beatHz.isFinite, (1...40).contains(beatHz),
              carrierHz + beatHz <= 840,
              gain.isFinite, (0...PsychoacousticGainPolicy.maximum).contains(gain),
              PsychoacousticMode(rawValue: modeRaw) != nil,
              noiseValid,
              sessionMinutes >= 0 && sessionMinutes < Int.max / 60,
              customSessionSeconds.map({ $0 >= 10 }) ?? true,
              [5, 10, 20, 30].contains(fadeDurationSeconds),
              PsychoacousticStageTimeline(stages: stages).isValid else { return false }
        if let selectedProgramRaw {
            guard let program = ExperimentalListeningProgram(rawValue: selectedProgramRaw) else {
                return false
            }
            if program != .threeStageArc {
                guard abs(carrierHz - program.initialLeftHz) < 0.000001,
                      abs(beatHz - program.initialBeatHz) < 0.000001 else { return false }
            }
        }
        return true
    }
}

struct PsychoacousticSoundPreset: Codable, Identifiable {
    let id: UUID
    let name: String
    let settings: PsychoacousticSoundSettings
}
