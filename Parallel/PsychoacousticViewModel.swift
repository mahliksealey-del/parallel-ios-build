import Combine
import Foundation

/// App-level fifth transport. The three AVPlayers and metronome remain
/// independent AudioSessionCoordinator sources.
@MainActor
final class PsychoacousticViewModel: ObservableObject, AudioPlaybackSource {
    @Published var carrierHz: Double = 200
    @Published var beatHz: Double = 10
    @Published var gain: Double = 0.15
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private weak var session: AudioSessionCoordinator?
    private let graph: AudioGraphCoordinator
    private let sourceID = AudioSourceID.psychoacoustic

    init(graph: AudioGraphCoordinator, coordinator: AudioSessionCoordinator) {
        self.graph = graph
        self.session = coordinator
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
    }

    func applyFrequencies() {
        guard parametersAreValid else {
            errorMessage = PsychoacousticAudioError.invalidParameters.localizedDescription
            return
        }
        guard isPlaying else { return }
        if graph.updatePsychoacousticFrequencies(
            left: carrierHz, right: carrierHz + beatHz
        ) {
            errorMessage = nil
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
        } else {
            errorMessage = PsychoacousticAudioError.controlQueueFull.localizedDescription
        }
    }

    func reportError(_ message: String) {
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
            gain: gain
        )
        isPlaying = true
        errorMessage = nil
    }

    func stop() {
        graph.stopPsychoacoustic()
        isPlaying = false
    }

    func markInterrupted() {
        graph.stopPsychoacoustic()
        isPlaying = false
    }

    func markRecovering() {
        graph.stopPsychoacoustic()
        isPlaying = false
    }

    private var parametersAreValid: Bool {
        carrierHz.isFinite && (100...800).contains(carrierHz)
        && beatHz.isFinite && (1...40).contains(beatHz)
        && gain.isFinite && (0...0.25).contains(gain)
    }
}
