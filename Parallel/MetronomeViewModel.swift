import Combine
import Foundation
import UIKit
import MetronomeEngine

@MainActor
final class MetronomeViewModel: ObservableObject {
    @Published private(set) var state: AudioCoordinatorState = .inactive
    @Published private(set) var errorMessage: String?
    @Published private(set) var routeDescription = "Audio route activates when playback starts."
    @Published var bpm = 120.0
    @Published var gain = 0.65
    var mixerLevel = 1.0
    @Published var boostedClicks = false
    @Published var clockSettings = ClockRhythmSettings()
    @Published private(set) var savedClockPresets: [MetronomeClockPreset] = []
    @Published private(set) var selectedClockPresetID: UUID?
    var minuteAnalysis: MinuteRhythmAnalysis? {
        ClockRhythmMath.analyze(bpm: bpm, settings: clockSettings)
    }
    @Published private(set) var isPlaying = false
    private var significantClockObserver: NSObjectProtocol?

    private let engine: MetronomeEngineProtocol
    let coordinator: AudioSessionCoordinator

    convenience init() {
        let engine = MetronomeEngine()
        let coordinator = AudioSessionCoordinator(graph: AudioGraphCoordinator(metronome: engine))
        self.init(engine: engine, coordinator: coordinator)
    }

    init(engine: MetronomeEngineProtocol, coordinator: AudioSessionCoordinator) {
        self.engine = engine
        self.coordinator = coordinator
        if let data = UserDefaults.standard.data(forKey: "metronome.clockSettings.v1"),
           let decoded = try? JSONDecoder().decode(ClockRhythmSettings.self, from: data),
           decoded.isValid {
            clockSettings = decoded
        }
        if let saved = UserDefaults.standard.object(forKey: "metronome.bpm.v1") as? Double,
           BeatFrameScheduler.bpmRange.contains(saved), saved.isFinite {
            bpm = saved
        }
        if let data = UserDefaults.standard.data(forKey: "metronome.presets.v1"),
           let decoded = try? JSONDecoder().decode([MetronomeClockPreset].self, from: data) {
            savedClockPresets = decoded.filter { $0.isValid }
        }
        if let raw = UserDefaults.standard.string(forKey: "metronome.selectedPreset.v1"),
           let id = UUID(uuidString: raw),
           savedClockPresets.contains(where: { $0.id == id }) {
            selectedClockPresetID = id
        }
        // Init is always stopped, so no player/audio session is touched.
        try? engine.setBPM(bpm)
        try? engine.setClockSettings(clockSettings)
        coordinator.onStateChange = { [weak self] state in
            self?.state = state
            self?.refreshMetronomeState()
            if case .failed(let message) = state { self?.errorMessage = message }
            else { self?.errorMessage = nil }
        }
        coordinator.onRouteChange = { [weak self] route in
            let names = route.outputs.isEmpty ? "Unknown output" : route.outputs.joined(separator: ", ")
            self?.routeDescription = "\(names) • \(Int(route.sampleRate)) Hz • \(route.outputChannels) ch"
        }
        // iOS announces manual/system clock or time-zone changes. Never
        // read Date or change clocks inside the PCM renderer; remap on a
        // separate control thread while preserving all other audio sources.
        significantClockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reanchorAfterSystemClockChange()
            }
        }
    }

    // The metronome transport is independent of the global session. The
    // session remains active when any of the three videos is playing.
    var canEditTempo: Bool { true }

    private func refreshMetronomeState() {
        isPlaying = coordinator.userRequestedPlayback && state == .active
    }

    func togglePlayback() {
        if coordinator.userRequestedPlayback {
            coordinator.stop()
        } else {
            clockSettings.sessionStartUnixSeconds = Date().timeIntervalSince1970
            applySettings()
            guard errorMessage == nil else { return }
            coordinator.start()
        }
        // state may remain .active throughout if a video keeps the shared
        // session alive; publish the metronome-specific transport explicitly.
        refreshMetronomeState()
    }

    func applyTempo() {
        do {
            if coordinator.userRequestedPlayback && state == .active {
                // The engine's render state is immutable while running. Stop
                // only its PCM graph, set BPM, then start that graph again
                // without interrupting AVPlayer audio or the AVAudioSession.
                try coordinator.reconfigureMetronome {
                    try self.engine.setBPM(self.bpm)
                }
            } else {
                try engine.setBPM(bpm)
            }
            errorMessage = nil
            UserDefaults.standard.set(bpm, forKey: "metronome.bpm.v1")
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshMetronomeState()
    }

    private func reanchorAfterSystemClockChange() {
        guard clockSettings.clockSync, coordinator.userRequestedPlayback,
              state == .active else { return }
        do {
            // Recreating just the metronome source captures a fresh matched
            // wall/host mapping. Other AVPlayers and psycho DSP keep playing.
            try coordinator.reconfigureMetronome {
                try self.engine.setClockSettings(self.clockSettings)
            }
            errorMessage = nil
        } catch {
            errorMessage = "Clock change: " + error.localizedDescription
        }
        refreshMetronomeState()
    }

    func applyClockSettings() {
        guard clockSettings.isValid else {
            errorMessage = "Unsupported clock, meter, or breathing settings."
            return
        }
        do {
            let audioChanged = !engine.clockSettings.hasSameAudioConfiguration(
                as: clockSettings)
            if coordinator.userRequestedPlayback && state == .active {
                if audioChanged {
                    // A real sound change rebuilds only the metronome source.
                    try coordinator.reconfigureMetronome {
                        try self.engine.setClockSettings(self.clockSettings)
                    }
                }
            } else {
                try engine.setClockSettings(clockSettings)
            }
            if let data = try? JSONEncoder().encode(clockSettings) {
                UserDefaults.standard.set(data, forKey: "metronome.clockSettings.v1")
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshMetronomeState()
    }

    func applyGain() {
        do { try engine.setGain(Float(gain * mixerLevel)) }
        catch { errorMessage = error.localizedDescription }
    }

    func applyClickBoost() {
        do {
            if coordinator.userRequestedPlayback && state == .active {
                // Rebuild only the metronome's immutable render state.
                // The three AVPlayers, psychoacoustic source and shared
                // audio-session playback intent must remain untouched.
                try coordinator.reconfigureMetronome {
                    try self.engine.setBoostedClicks(self.boostedClicks)
                }
            } else {
                try engine.setBoostedClicks(boostedClicks)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshMetronomeState()
    }

    /// Snapshot only metronome controls; loading a preset never begins audio.
    private var currentClockPresetSettings: ClockRhythmSettings {
        var settings = clockSettings
        settings.sessionStartUnixSeconds = nil
        return settings
    }

    func saveClockPreset(name: String) {
        guard !isPlaying else {
            errorMessage = "Stop metronome playback before saving a preset."
            return
        }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let preset = MetronomeClockPreset(
            id: UUID(), name: trimmed, bpm: bpm, settings: currentClockPresetSettings)
        guard preset.isValid else {
            errorMessage = "Choose a name and valid tempo/meter/breathing settings."
            return
        }
        savedClockPresets.append(preset)
        selectedClockPresetID = preset.id
        persistClockPresets()
        errorMessage = nil
    }

    func loadClockPreset(id: UUID) {
        guard !isPlaying, let preset = savedClockPresets.first(where: { $0.id == id }),
              preset.isValid else {
            errorMessage = "Stop playback and choose a valid metronome preset."
            return
        }
        bpm = preset.bpm
        clockSettings = preset.settings
        selectedClockPresetID = id
        applySettings()
        persistClockPresets()
    }

    func updateClockPreset(id: UUID) {
        guard !isPlaying,
              let index = savedClockPresets.firstIndex(where: { $0.id == id }) else {
            errorMessage = "Stop playback before updating a metronome preset."
            return
        }
        let updated = MetronomeClockPreset(
            id: id, name: savedClockPresets[index].name,
            bpm: bpm, settings: currentClockPresetSettings)
        guard updated.isValid else {
            errorMessage = "Invalid metronome settings; preset unchanged."
            return
        }
        savedClockPresets[index] = updated
        selectedClockPresetID = id
        persistClockPresets()
        errorMessage = nil
    }

    func deleteClockPreset(id: UUID) {
        guard !isPlaying else { return }
        savedClockPresets.removeAll { $0.id == id }
        if selectedClockPresetID == id { selectedClockPresetID = nil }
        persistClockPresets()
    }

    private func persistClockPresets() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(savedClockPresets) {
            defaults.set(data, forKey: "metronome.presets.v1")
        }
        if let id = selectedClockPresetID {
            defaults.set(id.uuidString, forKey: "metronome.selectedPreset.v1")
        } else {
            defaults.removeObject(forKey: "metronome.selectedPreset.v1")
        }
    }

    func retry() {
        errorMessage = nil
        applySettings()
        guard errorMessage == nil else { return }
        coordinator.start()
        refreshMetronomeState()
    }

    private func applySettings() {
        applyTempo()
        applyClockSettings()
        applyGain()
        applyClickBoost()
    }
}
