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

    private let engine: MetronomeEngineProtocol
    private let coordinator: AudioSessionCoordinator

    convenience init() {
        self.init(engine: MetronomeEngine())
    }

    init(engine: MetronomeEngineProtocol) {
        self.engine = engine
        self.coordinator = AudioSessionCoordinator(engine: engine)
        coordinator.onStateChange = { [weak self] state in
            self?.state = state
            if case .failed(let message) = state { self?.errorMessage = message }
            else { self?.errorMessage = nil }
        }
        coordinator.onRouteChange = { [weak self] route in
            let names = route.outputs.isEmpty ? "Unknown output" : route.outputs.joined(separator: ", ")
            self?.routeDescription = "\(names) • \(Int(route.sampleRate)) Hz • \(route.outputChannels) ch"
        }
    }

    var isPlaying: Bool { state == .active }
    var canEditTempo: Bool { state == .inactive || isFailed }

    func togglePlayback() {
        if coordinator.userRequestedPlayback { coordinator.stop() }
        else { applySettings(); guard errorMessage == nil else { return }; coordinator.start() }
    }

    func applyTempo() {
        guard canEditTempo else { return }
        do { try engine.setBPM(bpm) } catch { errorMessage = error.localizedDescription }
    }

    func applyGain() {
        do { try engine.setGain(Float(gain)) } catch { errorMessage = error.localizedDescription }
    }

    func retry() {
        errorMessage = nil
        applySettings()
        guard errorMessage == nil else { return }
        coordinator.start()
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }
    private func applySettings() { applyTempo(); applyGain() }
}
