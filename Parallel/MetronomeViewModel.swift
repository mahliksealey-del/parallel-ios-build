import Combine
import Foundation
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
    @Published private(set) var isPlaying = false

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

    func retry() {
        errorMessage = nil
        applySettings()
        guard errorMessage == nil else { return }
        coordinator.start()
        refreshMetronomeState()
    }

    private func applySettings() { applyTempo(); applyGain(); applyClickBoost() }
}
