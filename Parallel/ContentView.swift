import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: MetronomeViewModel
    let videos: [MediaMixerViewModel]
    @ObservedObject var pip: VideoPiPCoordinator
    @ObservedObject var psychoacoustic: PsychoacousticViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isDraggingTempo = false
    @State private var isDraggingCarrier = false
    @State private var isDraggingBeat = false
    @State private var isDraggingPsychoGain = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Video wall · MediaMixer") {
                    VStack(spacing: 12) {
                        // Always show all three live displays together when
                        // Parallel is active. Video 1 is reserved for future PiP.
                        MediaSlotCard(media: videos[0], pip: pip, foreground: scenePhase == .active,
                                      compact: false)
                        HStack(alignment: .top, spacing: 10) {
                            MediaSlotCard(media: videos[1], pip: pip, foreground: scenePhase == .active,
                                          compact: true)
                            MediaSlotCard(media: videos[2], pip: pip, foreground: scenePhase == .active,
                                          compact: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Section("Tempo") {
                    HStack {
                        Text("\(Int(model.bpm)) BPM").font(.title2.monospacedDigit().bold())
                        Spacer()
                        Stepper("Tempo", value: $model.bpm, in: 30...300, step: 1)
                            .labelsHidden()
                            .disabled(!model.canEditTempo)
                    }
                    Slider(
                        value: $model.bpm, in: 30...300, step: 1,
                        onEditingChanged: { editing in
                            isDraggingTempo = editing
                            if !editing { model.applyTempo() }
                        }
                    )
                        .disabled(!model.canEditTempo)
                        .accessibilityLabel("Tempo")
                        .accessibilityValue("\(Int(model.bpm)) beats per minute")
                }
                .onChange(of: model.bpm) { _ in
                    if !isDraggingTempo { model.applyTempo() }
                }

                Section("Metronome level") {
                    Slider(value: $model.gain, in: 0...1)
                        .accessibilityLabel("Metronome level")
                    Text("Independent linear gain: \(Int(model.gain * 100))%")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: model.gain) { _ in model.applyGain() }

                Section("Metronome click strength") {
                    Toggle("Stronger clicks (+4.3 dB)", isOn: $model.boostedClicks)
                        .accessibilityIdentifier("metronome-click-boost")
                    Text("Off by default. Increases generated click strength without raising iPhone system volume. Start low when using headphones.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: model.boostedClicks) { _ in model.applyClickBoost() }

                Section("Metronome playback") {
                    Button(model.isPlaying ? "Stop Metronome" : "Start Metronome") {
                        model.togglePlayback()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("metronome-transport")
                    LabeledContent("Status", value: model.isPlaying
                        ? "Metronome playing"
                        : (model.state == .interrupted ? "Interrupted" : "Metronome stopped"))
                    Text(model.routeDescription).font(.footnote).foregroundStyle(.secondary)
                }

                Section("PsychoacousticEngine · Stereo binaural") {
                    Text("Experimental audio synthesis. Stereo headphones required. No medical or performance effects are implied.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    LabeledContent("Left carrier",
                                   value: "\(Int(psychoacoustic.carrierHz)) Hz")
                    Slider(value: $psychoacoustic.carrierHz, in: 100...800, step: 1,
                           onEditingChanged: { editing in
                        isDraggingCarrier = editing
                        if !editing { psychoacoustic.applyFrequencies() }
                    })
                    .accessibilityLabel("Left carrier frequency")
                    .onChange(of: psychoacoustic.carrierHz) { _ in
                        if !isDraggingCarrier { psychoacoustic.applyFrequencies() }
                    }

                    LabeledContent("Binaural difference",
                                   value: "\(Int(psychoacoustic.beatHz)) Hz")
                    Slider(value: $psychoacoustic.beatHz, in: 1...40, step: 1,
                           onEditingChanged: { editing in
                        isDraggingBeat = editing
                        if !editing { psychoacoustic.applyFrequencies() }
                    })
                    .accessibilityLabel("Binaural frequency difference")
                    .onChange(of: psychoacoustic.beatHz) { _ in
                        if !isDraggingBeat { psychoacoustic.applyFrequencies() }
                    }
                    LabeledContent("EEG band analogy",
                                   value: psychoacoustic.bandLabel)
                    Text("This labels the sound's frequency difference, not your measured brainwaves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Right carrier",
                                   value: "\(Int(psychoacoustic.carrierHz + psychoacoustic.beatHz)) Hz")

                    LabeledContent("Psychoacoustic level",
                                   value: "\(Int(psychoacoustic.gain * 100))%")
                    Slider(value: $psychoacoustic.gain, in: 0...PsychoacousticGainPolicy.maximum,
                           onEditingChanged: { editing in
                        isDraggingPsychoGain = editing
                        if !editing { psychoacoustic.applyGain() }
                    })
                    .accessibilityLabel("Psychoacoustic level")
                    .onChange(of: psychoacoustic.gain) { _ in
                        if !isDraggingPsychoGain { psychoacoustic.applyGain() }
                    }
                    Text("Extended PCM gain: 50% maximum, up from 25%. Start low; this does not adjust TikTok or Instagram volume.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(psychoacoustic.isPlaying
                           ? "Stop Psychoacoustic Audio"
                           : "Start Psychoacoustic Audio") {
                        psychoacoustic.togglePlayback()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("psychoacoustic-transport")
                    LabeledContent("Status", value: psychoacoustic.isPlaying
                                   ? "Playing in stereo headphones" : "Stopped")
                }

                if let error = psychoacoustic.errorMessage {
                    Section("Psychoacoustic audio problem") {
                        Text(error).foregroundStyle(.red)
                    }
                }

                if let error = model.errorMessage {
                    Section("Audio problem") {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { model.retry() }
                    }
                }
            }
            .navigationTitle("Parallel")
        }
    }
}

// Separate @State for every Files picker, and separate @ObservedObject for
// every AVPlayer. Neither file replacement nor transport in one tile changes
// the player, intent, or slider values of its siblings.
private struct MediaSlotCard: View {
    @ObservedObject var media: MediaMixerViewModel
    @ObservedObject var pip: VideoPiPCoordinator
    let foreground: Bool
    let compact: Bool
    @State private var showingFileImporter = false
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 5) {
                Text("Video \(media.slot + 1)").font(compact ? .subheadline.bold() : .headline)
                Spacer(minLength: 2)
                Text(media.isPlaying ? "Playing" : (media.hasVideo ? "Paused" : "Empty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VideoSurface(
                player: media.player,
                isForeground: foreground,
                keepAttachedInBackground: media.slot == 0 && pip.shouldKeepLayerAttached,
                onCanvasReady: media.slot == 0 ? { canvas in pip.attach(to: canvas) } : nil
            )
                .frame(height: compact ? 88 : 168)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier("media-preview-\(media.slot + 1)")

            HStack(spacing: 6) {
                Button {
                    showingFileImporter = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(media.isImporting || (media.slot == 0 && pip.isActive))
                .accessibilityLabel("Import or replace Video \(media.slot + 1)")
                .accessibilityIdentifier("media-import-\(media.slot + 1)")

                Button {
                    media.togglePlayback()
                } label: {
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!media.hasVideo || media.isImporting)
                .accessibilityLabel("\(media.isPlaying ? "Pause" : "Play") Video \(media.slot + 1)")
                .accessibilityIdentifier("media-transport-\(media.slot + 1)")
            }

            // Local timeline scrubbing: sliding does not pause any other
            // video, the metronome, or the shared audio session.
            if media.canSeek {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubPosition : media.currentSeconds },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(1, media.durationSeconds),
                    onEditingChanged: { editing in
                        if editing {
                            scrubPosition = media.currentSeconds
                        } else {
                            media.seek(to: scrubPosition)
                        }
                        isScrubbing = editing
                    }
                )
                .accessibilityLabel("Video \(media.slot + 1) timeline")
                .accessibilityIdentifier("media-timeline-\(media.slot + 1)")
                HStack {
                    Text(MediaMixerViewModel.formatTimestamp(
                        isScrubbing ? scrubPosition : media.currentSeconds))
                    Spacer()
                    Text(MediaMixerViewModel.formatTimestamp(media.durationSeconds))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if media.slot == 0 {
                Button {
                    pip.toggle(for: media)
                } label: {
                    Label(pip.isActive ? "Close PiP" : "Start PiP",
                          systemImage: "pip.enter")
                }
                .buttonStyle(.bordered)
                .disabled(!media.hasVideo || !pip.isSupported)
                .accessibilityIdentifier("media-pip-1")
                if let pipError = pip.errorMessage {
                    Text(pipError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $media.volume, in: 0...1)
                    .onChange(of: media.volume) { _ in media.applyVolume() }
                    .accessibilityLabel("Video \(media.slot + 1) volume")
                    .accessibilityIdentifier("media-volume-\(media.slot + 1)")
            }
            Text(media.fileName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if media.isImporting {
                ProgressView("Importing...")
                    .font(.caption2)
            }
            if let error = media.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.movie]) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in await media.importVideo(from: url) }
            case .failure(let error):
                Task { @MainActor in media.reportError(error.localizedDescription) }
            }
        }
    }
}

// Unlike VideoPlayer, this surface has no built-in controls that can bypass
// AudioSessionCoordinator. Playback starts only via our own transport button.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer?
    let isForeground: Bool
    let keepAttachedInBackground: Bool
    let onCanvasReady: ((PlayerCanvas) -> Void)?

    func makeUIView(context: Context) -> PlayerCanvas {
        PlayerCanvas()
    }

    func updateUIView(_ view: PlayerCanvas, context: Context) {
        // A PiP transition keeps Video 1's source layer attached until iOS
        // finishes moving its frames into the floating window.
        view.updatePresentation(
            player: player, isForeground: isForeground || keepAttachedInBackground)
        onCanvasReady?(view)
    }
}

final class PlayerCanvas: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    // Disconnect the display, not the AVPlayer. The audio transport keeps
    // running under the shared AVAudioSession when iOS backgrounds the app.
    func updatePresentation(player: AVPlayer?, isForeground: Bool) {
        let desiredPlayer = isForeground ? player : nil
        if playerLayer.player !== desiredPlayer {
            playerLayer.player = desiredPlayer
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }
}


// Phase 2C: Only Video 1 may enter native Picture-in-Picture. A single app-
// lifetime controller is attached to Video 1's real on-screen AVPlayerLayer.
// Videos 2 and 3 are never registered for PiP; they stay audio-only when the
// app backgrounds. Their playback is owned by AudioSessionCoordinator.
@MainActor
final class VideoPiPCoordinator: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published private(set) var isActive = false
    @Published private(set) var isStarting = false
    @Published private(set) var errorMessage: String?

    private var controller: AVPictureInPictureController?
    private weak var canvas: PlayerCanvas?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var shouldKeepLayerAttached: Bool { isActive || isStarting }

    static func shouldAttachVideoLayer(foreground: Bool, pipActive: Bool,
                                       pipStarting: Bool) -> Bool {
        foreground || pipActive || pipStarting
    }

    func attach(to newCanvas: PlayerCanvas) {
        guard isSupported, !isActive, !isStarting else { return }
        guard canvas !== newCanvas || controller == nil else { return }
        canvas = newCanvas
        controller?.delegate = nil
        controller = AVPictureInPictureController(playerLayer: newCanvas.playerLayer)
        controller?.delegate = self
    }

    func toggle(for media: MediaMixerViewModel) {
        guard media.slot == 0 else { return }
        errorMessage = nil
        if let controller, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
            return
        }
        guard isSupported else {
            errorMessage = "Picture-in-Picture is unavailable on this device."
            return
        }
        guard media.isPlaying else {
            errorMessage = "Play Video 1 before starting Picture-in-Picture."
            return
        }
        guard let controller, controller.isPictureInPicturePossible else {
            errorMessage = "PiP is not ready. Keep Video 1 visible and playing, then try again."
            return
        }
        isStarting = true
        controller.startPictureInPicture()
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isStarting = false
            self?.isActive = true
            self?.errorMessage = nil
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.isStarting = false
            self?.isActive = false
            self?.errorMessage = "Could not start PiP: \(message)"
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isActive = false
            self?.isStarting = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
        completionHandler: @escaping (Bool) -> Void
    ) {
        // The only app screen already contains Video 1. iOS can restore it.
        completionHandler(true)
    }
}

#Preview {
    let audio = ParallelAudioContainer()
    ContentView(model: audio.metronome, videos: audio.videos,
                pip: audio.pip, psychoacoustic: audio.psychoacoustic)
}
