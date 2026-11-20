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

    var bandLabel: String { Self.bandLabel(for: beatHz) }

    private weak var session: AudioSessionCoordinator?
    private let graph: AudioGraphCoordinator
    private let sourceID = AudioSourceID.psychoacoustic
    private var stopTask: Task<Void, Never>?

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
        if isPlaying { scheduleStopIfNeeded() }
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
    }

    private func scheduleStopIfNeeded() {
        cancelSessionClock()
        // The psycho source owns this node. Do not affect the metronome/video paths.
        _ = graph.updatePsychoacousticOutputVolume(1)
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
                if remaining <= 0 {
                    _ = self.graph.updatePsychoacousticOutputVolume(0)
                    self.session?.stopPlayback(for: self.sourceID)
                    return
                }
                if remaining <= PsychoacousticSessionEnvelope.fadeSeconds {
                    self.fadeRemainingSeconds = remaining
                    _ = self.graph.updatePsychoacousticOutputVolume(
                        Double(PsychoacousticSessionEnvelope.gain(remaining: remaining)))
                } else {
                    self.fadeRemainingSeconds = nil
                }
                // Control-rate envelope for this initial prototype. True
                // sample-accurate fading and background tails need device tests.
                do {
                    try await Task.sleep(nanoseconds:
                        remaining <= PsychoacousticSessionEnvelope.fadeSeconds
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

    static func gain(remaining: TimeInterval) -> Float {
        let u = 1 - min(1, max(0, remaining / fadeSeconds))
        return Float(0.5 * (1 + cos(.pi * u)))
    }
}
