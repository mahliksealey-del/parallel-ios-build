import AVFoundation
import Foundation

struct AudioRouteSnapshot: Equatable {
    let sampleRate: Double
    let outputChannels: Int
    let ioBufferDuration: TimeInterval
    let outputs: [String]
}

protocol AudioSessionControlling: AnyObject {
    var sampleRate: Double { get }
    var outputNumberOfChannels: Int { get }
    var ioBufferDuration: TimeInterval { get }
    var outputNames: [String] { get }
    func configureForMixedPlayback() throws
    func activate() throws
    func deactivate() throws
}

final class SystemAudioSession: AudioSessionControlling {
    private let session = AVAudioSession.sharedInstance()
    var sampleRate: Double { session.sampleRate }
    var outputNumberOfChannels: Int { session.outputNumberOfChannels }
    var ioBufferDuration: TimeInterval { session.ioBufferDuration }
    var outputNames: [String] { session.currentRoute.outputs.map(\.portName) }
    func configureForMixedPlayback() throws {
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }
    func activate() throws { try session.setActive(true) }
    func deactivate() throws { try session.setActive(false, options: [.notifyOthersOnDeactivation]) }
}

enum AudioSourceID: Hashable {
    case metronome
    case media(Int)

    fileprivate var sortKey: Int {
        switch self {
        case .metronome: return 0
        case .media(let slot): return slot + 1
        }
    }
}

enum AudioCoordinatorState: Equatable {
    case inactive, activating, active, interrupted, recovering
    case failed(String)

    var label: String {
        switch self {
        case .inactive: return "Stopped"
        case .activating: return "Starting"
        case .active: return "Playing"
        case .interrupted: return "Interrupted"
        case .recovering: return "Recovering"
        case .failed: return "Needs attention"
        }
    }
}

@MainActor
final class AudioSessionCoordinator {
    private let session: AudioSessionControlling
    private let graph: AudioGraphControlling
    private let notificationCenter: NotificationCenter
    private var sources: [AudioSourceID: AudioPlaybackSource]
    private(set) var requestedSources: Set<AudioSourceID> = []
    private var sessionActivated = false
    private(set) var state: AudioCoordinatorState = .inactive { didSet { onStateChange?(state) } }
    private(set) var route: AudioRouteSnapshot?
    var userRequestedPlayback: Bool { requestedSources.contains(.metronome) }
    var onStateChange: ((AudioCoordinatorState) -> Void)?
    var onRouteChange: ((AudioRouteSnapshot) -> Void)?
    var onSourceError: ((AudioSourceID, String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(session: AudioSessionControlling = SystemAudioSession(),
         graph: AudioGraphControlling,
         notificationCenter: NotificationCenter = .default,
         observeSystemNotifications: Bool = true) {
        self.session = session
        self.graph = graph
        self.sources = [.metronome: graph]
        self.notificationCenter = notificationCenter
        graph.onConfigurationChange = { [weak self] in self?.engineConfigurationChanged() }
        if observeSystemNotifications { installObservers() }
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    @discardableResult
    func register(_ source: AudioPlaybackSource, for id: AudioSourceID) -> Bool {
        guard id != .metronome, sources[id] == nil else { return false }
        sources[id] = source
        return true
    }

    func unregister(_ id: AudioSourceID) {
        guard id != .metronome else { return }
        stopPlayback(for: id)
        sources.removeValue(forKey: id)
    }

    func start() { requestPlayback(for: .metronome) }
    func stop() { stopPlayback(for: .metronome) }

    func requestPlayback(for id: AudioSourceID) {
        guard let source = sources[id] else {
            onSourceError?(id, "Audio source is not registered.")
            return
        }
        guard !requestedSources.contains(id) else { return }
        requestedSources.insert(id)

        if state == .interrupted {
            source.markInterrupted()
            return
        }

        if sessionActivated {
            do {
                try source.start(sampleRate: session.sampleRate)
                state = .active
            } catch {
                source.stop()
                requestedSources.remove(id)
                onSourceError?(id, error.localizedDescription)
            }
            return
        }

        startRequestedPlayback(recovery: false)
    }

    func stopPlayback(for id: AudioSourceID) {
        guard requestedSources.remove(id) != nil else { return }
        sources[id]?.stop()
        guard requestedSources.isEmpty else { return }
        do {
            try deactivateSessionIfNeeded()
            state = .inactive
        } catch {
            state = .failed("Playback stopped, but the audio session could not deactivate: \(error.localizedDescription)")
        }
    }

    // Rebuild only the metronome audio graph for live tempo edits. Every
    // media AVPlayer and the shared audio-session activation remain untouched.
    func reconfigureMetronome(_ updateEngine: () throws -> Void) throws {
        guard requestedSources.contains(.metronome), sessionActivated else {
            try updateEngine()
            return
        }
        graph.stop()
        do {
            try updateEngine()
            try graph.start(sampleRate: session.sampleRate)
            state = .active
        } catch {
            graph.stop()
            requestedSources.remove(.metronome)
            onSourceError?(.metronome, error.localizedDescription)
            if requestedSources.isEmpty {
                try? deactivateSessionIfNeeded()
                state = .failed(error.localizedDescription)
            } else {
                state = .active
            }
            throw error
        }
    }

    func interruptionBegan() {
        guard !requestedSources.isEmpty else { return }
        for id in requestedSources { sources[id]?.markInterrupted() }
        sessionActivated = false
        state = .interrupted
    }

    func interruptionEnded(shouldResume: Bool) {
        guard !requestedSources.isEmpty else { return }
        guard shouldResume else {
            for id in requestedSources { sources[id]?.stop() }
            requestedSources.removeAll()
            sessionActivated = false
            state = .inactive
            return
        }
        startRequestedPlayback(recovery: true)
    }

    func outputDeviceWasRemoved() {
        guard !requestedSources.isEmpty else { return }
        for id in requestedSources { sources[id]?.stop() }
        requestedSources.removeAll()
        try? deactivateSessionIfNeeded()
        state = .failed("Audio output disconnected. Playback stopped to reduce the risk of speaker fallback.")
    }

    func routeChanged() { refreshRoute() }

    func mediaServicesWereLost() {
        guard !requestedSources.isEmpty else { return }
        for id in requestedSources { sources[id]?.markInterrupted() }
        sessionActivated = false
        state = .interrupted
    }

    func mediaServicesWereReset() {
        guard !requestedSources.isEmpty else { return }
        startRequestedPlayback(recovery: true)
    }

    func engineConfigurationChanged() {
        guard requestedSources.contains(.metronome), state == .active else { return }
        state = .recovering
        graph.markRecovering()
        do {
            refreshRoute()
            guard session.sampleRate.isFinite, session.sampleRate > 0 else {
                throw InvalidAudioRoute.sampleRate
            }
            try graph.start(sampleRate: session.sampleRate)
            state = .active
        } catch {
            graph.stop()
            requestedSources.remove(.metronome)
            onSourceError?(.metronome, error.localizedDescription)
            if requestedSources.isEmpty {
                do {
                    try deactivateSessionIfNeeded()
                    state = .failed(error.localizedDescription)
                } catch {
                    state = .failed("Recovery and session deactivation failed: \(error.localizedDescription)")
                }
            } else {
                state = .active
            }
        }
    }

    private func startRequestedPlayback(recovery: Bool) {
        guard !requestedSources.isEmpty else { return }
        state = recovery ? .recovering : .activating
        if recovery {
            for id in requestedSources { sources[id]?.markRecovering() }
        }
        do {
            try session.configureForMixedPlayback()
            try session.activate()
            sessionActivated = true
            refreshRoute()
            guard session.sampleRate.isFinite, session.sampleRate > 0 else {
                throw InvalidAudioRoute.sampleRate
            }
            for id in requestedSources.sorted(by: { $0.sortKey < $1.sortKey }) {
                try sources[id]?.start(sampleRate: session.sampleRate)
            }
            state = .active
        } catch {
            for id in requestedSources { sources[id]?.stop() }
            requestedSources.removeAll()
            try? deactivateSessionIfNeeded()
            state = .failed(error.localizedDescription)
        }
    }

    private func deactivateSessionIfNeeded() throws {
        guard sessionActivated else { return }
        try session.deactivate()
        sessionActivated = false
    }

    private func refreshRoute() {
        let snapshot = AudioRouteSnapshot(
            sampleRate: session.sampleRate,
            outputChannels: session.outputNumberOfChannels,
            ioBufferDuration: session.ioBufferDuration,
            outputs: session.outputNames
        )
        route = snapshot
        onRouteChange?(snapshot)
    }

    private func installObservers() {
        let sessionObject = AVAudioSession.sharedInstance()
        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: sessionObject, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        })
        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: sessionObject, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        })
        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: sessionObject, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereLost() }
        })
        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: sessionObject, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began: interruptionBegan()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume))
        @unknown default: interruptionBegan()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable {
            outputDeviceWasRemoved()
        } else {
            routeChanged()
        }
    }
}

private enum InvalidAudioRoute: LocalizedError {
    case sampleRate
    var errorDescription: String? { "The active audio route has no valid sample rate." }
}
