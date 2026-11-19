import AVFoundation
import Combine
import Foundation

enum MediaImportError: LocalizedError {
    case unsupportedType
    case invalidVideo
    case noVideo

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "Choose a local MP4, MOV, or M4V video."
        case .invalidVideo: return "The selected file does not contain a playable video track."
        case .noVideo: return "Import a video before starting playback."
        }
    }
}

// Uses Files security-scoped access only while copying; playback always reads
// an app-owned local file. No external document URL is persisted.
enum ManagedVideoFileStore {
    static func copy(from source: URL) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw MediaImportError.unsupportedType }

        let manager = FileManager.default
        let root = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("MediaMixer", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)

        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: source, options: [], error: &coordinationError
            ) { readableURL in
                do { try manager.copyItem(at: readableURL, to: destination) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            guard manager.fileExists(atPath: destination.path) else {
                throw MediaImportError.invalidVideo
            }
            var backupURL = destination
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? backupURL.setResourceValues(resourceValues)
            return destination
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    static func delete(_ url: URL) {
        // Callers only supply paths produced by copy(from:); never delete an
        // external Files URL.
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class MediaMixerViewModel: ObservableObject, AudioPlaybackSource {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var fileName = "No video selected"
    @Published private(set) var status = "Import a video to begin."
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isImporting = false
    @Published private(set) var durationSeconds = 0.0
    @Published private(set) var currentSeconds = 0.0
    @Published var volume = 0.65
    @Published var boostedAudio = false

    private weak var coordinator: AudioSessionCoordinator?
    let slot: Int
    private let sourceID: AudioSourceID
    private var managedFile: URL?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var observedPlayer: AVPlayer?
    private var timeObserver: Any?
    private var itemToken = UUID()

    init(coordinator: AudioSessionCoordinator, slot: Int = 0) {
        precondition((0..<3).contains(slot), "MediaMixer supports only slots 0, 1, and 2.")
        self.slot = slot
        self.sourceID = .media(slot)
        self.coordinator = coordinator
        precondition(coordinator.register(self, for: sourceID), "Video slot already registered.")
    }

    var hasVideo: Bool { player != nil }
    var canSeek: Bool { hasVideo && durationSeconds.isFinite && durationSeconds > 0 }

    static func validatedSeekTime(_ requested: Double, duration: Double) -> Double? {
        guard requested.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(max(0, requested), duration)
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    // Seek only this player's timeline; leave coordinator source intent and
    // the other two independent AVPlayers untouched.
    func seek(to seconds: Double) {
        guard let player,
              let target = Self.validatedSeekTime(seconds, duration: durationSeconds) else { return }
        currentSeconds = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // Video presentation is detached when the app becomes inactive, so
    // AVPlayer should retain its audio transport while in the background.
    static func configureForBackgroundPlayback(_ player: AVPlayer) {
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }

    func togglePlayback() {
        guard let coordinator else { return }
        if coordinator.requestedSources.contains(sourceID) {
            coordinator.stopPlayback(for: sourceID)
        } else {
            guard player != nil else {
                reportError(MediaImportError.noVideo.localizedDescription)
                return
            }
            errorMessage = nil
            coordinator.requestPlayback(for: sourceID)
        }
    }

    func applyVolume() {
        guard volume.isFinite, (0...1).contains(volume) else {
            reportError("Video volume must be between 0 and 100%.")
            return
        }
        player?.volume = Float(volume)
    }

    func applyAudioBoost() async {
        guard let item = player?.currentItem else { return }
        if !boostedAudio {
            item.audioMix = nil
            return
        }
        do {
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first,
                  let mix = VideoAudioBoostFactory.makeAudioMix(for: track) else {
                boostedAudio = false
                reportError("Boost is unavailable for this video's audio format.")
                return
            }
            item.audioMix = mix
            errorMessage = nil
        } catch {
            boostedAudio = false
            reportError("Could not enable video audio boost: \(error.localizedDescription)")
        }
    }

    func reportError(_ message: String) {
        errorMessage = message
        status = "Needs attention"
    }

    func importVideo(from source: URL) async {
        guard !isImporting else { return }
        isImporting = true
        errorMessage = nil
        status = "Importing video..."
        defer { isImporting = false }

        var copiedFile: URL?
        do {
            // External iCloud / Files I/O must not block the main UI actor.
            let localFile = try await Task.detached(priority: .userInitiated) {
                try ManagedVideoFileStore.copy(from: source)
            }.value
            copiedFile = localFile

            let asset = AVURLAsset(url: localFile)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            guard playable, !tracks.isEmpty else { throw MediaImportError.invalidVideo }

            let nextItem = AVPlayerItem(asset: asset)
            let nextPlayer = AVPlayer(playerItem: nextItem)
            Self.configureForBackgroundPlayback(nextPlayer)
            nextPlayer.volume = Float(volume)

            coordinator?.stopPlayback(for: sourceID)
            removeObservers()
            let oldFile = managedFile
            player?.pause()
            player = nextPlayer
            fileName = source.lastPathComponent
            managedFile = localFile
            isPlaying = false
            currentSeconds = 0
            durationSeconds = (duration.isNumeric && duration.seconds.isFinite && duration.seconds > 0)
                ? duration.seconds : 0
            status = "Ready to play"
            observe(item: nextItem, player: nextPlayer)
            if boostedAudio { await applyAudioBoost() }
            if let oldFile { ManagedVideoFileStore.delete(oldFile) }
        } catch {
            if let copiedFile { ManagedVideoFileStore.delete(copiedFile) }
            reportError(error.localizedDescription)
        }
    }

    func start(sampleRate: Double) throws {
        guard let player else { throw MediaImportError.noVideo }
        player.play()
        isPlaying = true
        status = "Playing"
    }

    func stop() {
        player?.pause()
        isPlaying = false
        status = hasVideo ? "Paused" : "Import a video to begin."
    }

    func markInterrupted() {
        player?.pause()
        isPlaying = false
        status = "Interrupted"
    }

    func markRecovering() {
        player?.pause()
        isPlaying = false
        status = "Restoring playback"
    }

    private func observe(item: AVPlayerItem, player: AVPlayer) {
        itemToken = UUID()
        let token = itemToken
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.itemToken == token, time.seconds.isFinite else { return }
                self.currentSeconds = min(max(0, time.seconds), max(0, self.durationSeconds))
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playbackEnded(token: token) }
        }
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playbackFailed(token: token) }
        }
    }

    private func playbackEnded(token: UUID) {
        guard token == itemToken else { return }
        coordinator?.stopPlayback(for: sourceID)
        player?.seek(to: .zero)
        status = "Finished"
    }

    private func playbackFailed(token: UUID) {
        guard token == itemToken else { return }
        coordinator?.stopPlayback(for: sourceID)
        reportError("This video could not finish playback.")
    }

    private func removeObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        endObserver = nil
        failedObserver = nil
        timeObserver = nil
        observedPlayer = nil
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
    }
}
