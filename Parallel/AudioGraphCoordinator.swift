import AVFoundation
import Foundation
import MetronomeEngine

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

// Only this app-level object owns AVAudioEngine. AVPlayer audio is a separate
// system-managed path, not an implicit input to this PCM graph.
@MainActor
final class AudioGraphCoordinator: AudioGraphControlling {
    private let metronome: MetronomeEngineProtocol
    private var audioEngine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var graphToken: UUID?
    var onConfigurationChange: (() -> Void)?

    init(metronome: MetronomeEngineProtocol) {
        self.metronome = metronome
    }

    func start(sampleRate: Double) throws {
        if audioEngine?.isRunning == true { return }
        tearDownGraph()
        let nodes = try metronome.makeNodes(sampleRate: sampleRate)
        let graph = AVAudioEngine()
        graph.attach(nodes.source)
        graph.attach(nodes.gainMixer)
        graph.connect(nodes.source, to: nodes.gainMixer, format: nodes.format)
        graph.connect(nodes.gainMixer, to: graph.mainMixerNode, format: nodes.format)
        graph.prepare()

        do {
            try graph.start()
        } catch {
            graph.stop()
            graph.detach(nodes.source)
            graph.detach(nodes.gainMixer)
            let wrapped = MetronomeEngineError.graphStartFailed(error.localizedDescription)
            metronome.markFailed(wrapped.localizedDescription)
            throw wrapped
        }

        audioEngine = graph
        metronome.markPlaying()
        let token = UUID()
        graphToken = token
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: graph, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.graphToken == token else { return }
                self.tearDownGraph()
                self.metronome.markRecovering()
                self.onConfigurationChange?()
            }
        }
    }

    func stop() {
        tearDownGraph()
        metronome.stop()
    }

    func markInterrupted() {
        tearDownGraph()
        metronome.markInterrupted()
    }

    func markRecovering() {
        tearDownGraph()
        metronome.markRecovering()
    }

    private func tearDownGraph() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        graphToken = nil
        audioEngine?.stop()
        audioEngine = nil
    }
}
