import AVFoundation
import Foundation
import MetronomeEngine
import PsychoacousticDSP

// All transports use the existing application audio session.
@MainActor
protocol AudioPlaybackSource: AnyObject {
    func start(sampleRate: Double) throws
    func stop()
    func markInterrupted()
    func markRecovering()
}

@MainActor
protocol AudioGraphControlling: AudioPlaybackSource {
    var onConfigurationChange: (() -> Void)? { get set }
}

/// One shared AVAudioEngine for generated PCM; three AVPlayers are system-managed.
/// Each generated source attaches its own source and gain mixer. Stopping the
/// metronome does NOT stop the psychoacoustic source, and vice versa.
@MainActor
final class AudioGraphCoordinator: AudioGraphControlling {
    private let metronome: MetronomeEngineProtocol
    private let emergencyRelay: PsychoacousticEmergencyRelay
    private var audioEngine: AVAudioEngine?
    private var sampleRate: Double?
    private var metronomeNodes: MetronomeAudioNodes?
    private var psychoacousticNodes: PsychoacousticAudioNodes?
    private var metronomeActive = false
    private var psychoacousticActive = false
    private var configurationObserver: NSObjectProtocol?
    private var graphToken: UUID?
    var onConfigurationChange: (() -> Void)?

    init(metronome: MetronomeEngineProtocol,
         emergencyRelay: PsychoacousticEmergencyRelay = PsychoacousticEmergencyRelay()) {
        self.metronome = metronome
        self.emergencyRelay = emergencyRelay
    }

    func start(sampleRate: Double) throws {
        guard !metronomeActive else { return }
        let graph = try ensureGraph(sampleRate: sampleRate)
        let nodes = try metronome.makeNodes(sampleRate: sampleRate)
        graph.attach(nodes.source)
        graph.attach(nodes.gainMixer)
        graph.connect(nodes.source, to: nodes.gainMixer, format: nodes.format)
        graph.connect(nodes.gainMixer, to: graph.mainMixerNode, format: nodes.format)
        do {
            try ensureRunning(graph)
            metronomeNodes = nodes
            metronomeActive = true
            metronome.markPlaying()
        } catch {
            nodes.gainMixer.outputVolume = 0
            graph.detach(nodes.source)
            graph.detach(nodes.gainMixer)
            let wrapped = MetronomeEngineError.graphStartFailed(error.localizedDescription)
            metronome.markFailed(wrapped.localizedDescription)
            if !psychoacousticActive { tearDownGraph() }
            throw wrapped
        }
    }

    func stop() {
        metronomeActive = false
        if let nodes = metronomeNodes, let graph = audioEngine {
            nodes.gainMixer.outputVolume = 0
            graph.detach(nodes.source)
            graph.detach(nodes.gainMixer)
        }
        metronomeNodes = nil
        metronome.stop()
        if !psychoacousticActive { tearDownGraph() }
    }

    func startPsychoacoustic(
        sampleRate: Double,
        leftHz: Double,
        rightHz: Double,
        gain: Double,
        mode: PsychoacousticMode = .binaural,
        noise: NoiseLevels = .init()
    ) throws {
        guard !psychoacousticActive else { return }
        // Verify again immediately before arming the atomic audio gate.
        guard PsychoacousticOutputPolicy.stereoHeadphonesAvailable() else {
            throw PsychoacousticAudioError.headphonesRequired
        }
        let graph = try ensureGraph(sampleRate: sampleRate)
        let nodes = try PsychoacousticAudioNodes.make(
            sampleRate: sampleRate, leftHz: leftHz, rightHz: rightHz,
            targetGain: gain, mode: mode, noise: noise
        )
        emergencyRelay.bind(nodes.owner)
        graph.attach(nodes.source)
        graph.attach(nodes.gainMixer)
        graph.connect(nodes.source, to: nodes.gainMixer, format: nodes.format)
        graph.connect(nodes.gainMixer, to: graph.mainMixerNode, format: nodes.format)
        do {
            try ensureRunning(graph)
            psychoacousticNodes = nodes
            psychoacousticActive = true
        } catch {
            nodes.owner.disarmImmediately()
            nodes.gainMixer.outputVolume = 0
            graph.detach(nodes.source)
            graph.detach(nodes.gainMixer)
            emergencyRelay.bind(nil)
            if !metronomeActive { tearDownGraph() }
            throw PsychoacousticAudioError.startFailed(error.localizedDescription)
        }
    }

    func stopPsychoacoustic() {
        // Hardware-route notifications also reach this relay directly without
        // waiting for a MainActor hop. The render callback never takes its lock.
        emergencyRelay.disarmImmediately()
        psychoacousticActive = false
        if let nodes = psychoacousticNodes, let graph = audioEngine {
            nodes.gainMixer.outputVolume = 0
            graph.detach(nodes.source)
            graph.detach(nodes.gainMixer)
        }
        psychoacousticNodes = nil
        emergencyRelay.bind(nil)
        if !metronomeActive { tearDownGraph() }
    }

    func updatePsychoacousticFrequencies(left: Double, right: Double) -> Bool {
        guard psychoacousticActive, let nodes = psychoacousticNodes,
              let sampleRate else { return false }
        return nodes.setFrequencies(
            left: left, right: right,
            transitionFrames: Int(sampleRate * 0.12)
        )
    }

    func updatePsychoacousticGain(_ gain: Double) -> Bool {
        guard psychoacousticActive, let nodes = psychoacousticNodes,
              let sampleRate else { return false }
        return nodes.setGain(gain, fadeFrames: Int(sampleRate * 0.04))
    }

    func updatePsychoacousticMode(_ mode: PsychoacousticMode) -> Bool {
        psychoacousticNodes?.setMode(mode) ?? false
    }

    func updatePsychoacousticNoise(_ noise: NoiseLevels) -> Bool {
        psychoacousticNodes?.setNoise(noise) ?? false
    }

    func markInterrupted() {
        tearDownGraph()
        metronome.markInterrupted()
    }

    func markRecovering() {
        tearDownGraph()
        metronome.markRecovering()
    }

    private func ensureGraph(sampleRate desiredRate: Double) throws -> AVAudioEngine {
        guard desiredRate.isFinite && desiredRate > 0 else {
            throw MetronomeEngineError.invalidSampleRate
        }
        if let graph = audioEngine {
            guard sampleRate == desiredRate else {
                // Recovery must first stop all PCM sources. A stale callback
                // cannot silently continue with the wrong sample rate.
                throw PsychoacousticAudioError.unsupportedAudioFormat
            }
            return graph
        }
        let graph = AVAudioEngine()
        audioEngine = graph
        sampleRate = desiredRate
        installObserver(for: graph)
        return graph
    }

    private func ensureRunning(_ graph: AVAudioEngine) throws {
        if graph.isRunning { return }
        graph.prepare()
        try graph.start()
    }

    private func installObserver(for graph: AVAudioEngine) {
        let token = UUID()
        graphToken = token
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: graph, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.graphToken == token else { return }
                self.tearDownGraph()
                self.onConfigurationChange?()
            }
        }
    }

    private func tearDownGraph() {
        emergencyRelay.disarmImmediately()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        graphToken = nil
        audioEngine?.stop()
        audioEngine = nil
        sampleRate = nil
        metronomeNodes = nil
        psychoacousticNodes = nil
        metronomeActive = false
        psychoacousticActive = false
        emergencyRelay.bind(nil)
    }
}
