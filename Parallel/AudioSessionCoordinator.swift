import AVFoundation
import Foundation
import MetronomeEngine

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
    func configureForMixedPlayback() throws { try session.setCategory(.playback, mode: .default, options: [.mixWithOthers]) }
    func activate() throws { try session.setActive(true) }
    func deactivate() throws { try session.setActive(false, options: [.notifyOthersOnDeactivation]) }
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
    private let engine: MetronomeEngineProtocol
    private let notificationCenter: NotificationCenter
    private(set) var state: AudioCoordinatorState = .inactive { didSet { onStateChange?(state) } }
    private(set) var route: AudioRouteSnapshot?
    private(set) var userRequestedPlayback = false
    var onStateChange: ((AudioCoordinatorState) -> Void)?
    var onRouteChange: ((AudioRouteSnapshot) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(session: AudioSessionControlling = SystemAudioSession(), engine: MetronomeEngineProtocol,
         notificationCenter: NotificationCenter = .default, observeSystemNotifications: Bool = true) {
        self.session = session
        self.engine = engine
        self.notificationCenter = notificationCenter
        engine.onConfigurationChange = { [weak self] in self?.engineConfigurationChanged() }
        if observeSystemNotifications { installObservers() }
    }

    deinit { for observer in observers { notificationCenter.removeObserver(observer) } }

    func start() {
        guard !userRequestedPlayback else { return }
        userRequestedPlayback = true
        startRequestedPlayback(recovery: false)
    }

    func stop() {
        userRequestedPlayback = false
        engine.stop()
        do { try session.deactivate(); state = .inactive }
        catch { state = .failed("Playback stopped, but the audio session could not deactivate: \(error.localizedDescription)") }
    }

    func interruptionBegan() {
        guard userRequestedPlayback else { return }
        engine.markInterrupted()
        state = .interrupted
    }

    func interruptionEnded(shouldResume: Bool) {
        guard userRequestedPlayback else { return }
        guard shouldResume else { userRequestedPlayback = false; state = .inactive; return }
        startRequestedPlayback(recovery: true)
    }

    func outputDeviceWasRemoved() {
        guard userRequestedPlayback else { return }
        userRequestedPlayback = false
        engine.stop()
        try? session.deactivate()
        state = .failed("Audio output disconnected. Playback was paused to prevent sound moving to the speaker.")
    }

    func routeChanged() { refreshRoute() }
    func mediaServicesWereLost() { guard userRequestedPlayback else { return }; engine.markInterrupted(); state = .interrupted }
    func mediaServicesWereReset() { guard userRequestedPlayback else { return }; startRequestedPlayback(recovery: true) }
    func engineConfigurationChanged() { guard userRequestedPlayback else { return }; startRequestedPlayback(recovery: true) }

    private func startRequestedPlayback(recovery: Bool) {
        state = recovery ? .recovering : .activating
        if recovery { engine.markRecovering() }
        do {
            try session.configureForMixedPlayback()
            try session.activate()
            refreshRoute()
            guard session.sampleRate > 0 else { throw MetronomeEngineError.invalidSampleRate }
            try engine.start(sampleRate: session.sampleRate)
            guard engine.state == .playing else { throw MetronomeEngineError.graphStartFailed("The engine did not enter its playing state.") }
            state = .active
        } catch {
            engine.stop()
            try? session.deactivate()
            userRequestedPlayback = false
            state = .failed(error.localizedDescription)
        }
    }

    private func refreshRoute() {
        let snapshot = AudioRouteSnapshot(sampleRate: session.sampleRate,
            outputChannels: session.outputNumberOfChannels, ioBufferDuration: session.ioBufferDuration,
            outputs: session.outputNames)
        route = snapshot
        onRouteChange?(snapshot)
    }

    private func installObservers() {
        let sessionObject = AVAudioSession.sharedInstance()
        observers.append(notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification,
            object: sessionObject, queue: .main) { [weak self] notification in
                Task { @MainActor in self?.handleInterruption(notification) }
            })
        observers.append(notificationCenter.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: sessionObject, queue: .main) { [weak self] notification in
                Task { @MainActor in self?.handleRouteChange(notification) }
            })
        observers.append(notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification,
            object: sessionObject, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.mediaServicesWereLost() }
            })
        observers.append(notificationCenter.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: sessionObject, queue: .main) { [weak self] _ in
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
        } else { routeChanged() }
    }
}
