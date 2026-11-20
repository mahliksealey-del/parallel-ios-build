import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PsychoacousticDSP

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
    // First-party channel trim is independent of the original per-source controls.
    @State private var showingMiniMixer = false
    @State private var channelTrims: [Double] = Array(repeating: 1, count: 5)
    @State private var mutedChannels: Set<Int> = []
    @State private var soloChannels: Set<Int> = []

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

                Section {
                    Button {
                        showingMiniMixer = true
                    } label: {
                        Label("Mini Mixer", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("parallel-mini-mixer")
                    Text("Optional five-source controls. The original video wall stays unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Section("PsychoacousticEngine") {
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
                    .disabled(psychoacoustic.selectedProgram != nil)
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
                    .disabled(psychoacoustic.selectedProgram != nil)
                    .onChange(of: psychoacoustic.beatHz) { _ in
                        if !isDraggingBeat { psychoacoustic.applyFrequencies() }
                    }
                    LabeledContent("EEG band analogy",
                                   value: psychoacoustic.bandLabel)
                    Text("This labels the sound's frequency difference, not your measured brainwaves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Generation mode", selection: $psychoacoustic.mode) {
                        Text("Binaural · separate ears").tag(PsychoacousticMode.binaural)
                        Text("Monaural · mixed tones").tag(PsychoacousticMode.monaural)
                        Text("Isochronic · pulsed tone").tag(PsychoacousticMode.isochronic)
                    }
                    .onChange(of: psychoacoustic.mode) { _ in psychoacoustic.applyLayers() }
                    .disabled(psychoacoustic.selectedProgram != nil)
                    Text(psychoacoustic.mode == .binaural
                         ? "Each ear receives a different carrier; stereo headphones are required."
                         : psychoacoustic.mode == .monaural
                         ? "Both ears receive the same two-tone amplitude pattern."
                         : "Both ears receive a smoothly gated tone at the selected pulse rate.")
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

                Section("Procedural noise layers") {
                    noiseSlider("White noise", value: $psychoacoustic.whiteNoise)
                    noiseSlider("Pink noise", value: $psychoacoustic.pinkNoise)
                    noiseSlider("Brown noise", value: $psychoacoustic.brownNoise)
                    Text("Original deterministic generators. Levels are capped at 20% and mixed through a digital peak limiter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: psychoacoustic.whiteNoise) { _ in psychoacoustic.applyLayers() }
                .onChange(of: psychoacoustic.pinkNoise) { _ in psychoacoustic.applyLayers() }
                .onChange(of: psychoacoustic.brownNoise) { _ in psychoacoustic.applyLayers() }

                Section("Presets and session") {
                    HStack {
                        Button("Focus") { psychoacoustic.applyPreset(.focus) }
                        Button("Calm") { psychoacoustic.applyPreset(.calm) }
                        Button("Rest") { psychoacoustic.applyPreset(.rest) }
                    }
                    Picker("Stop after", selection: $psychoacoustic.sessionMinutes) {
                        Text("Manual").tag(0)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                    }
                    .onChange(of: psychoacoustic.sessionMinutes) { _ in
                        psychoacoustic.applySessionTimer()
                    }
                    Picker("End fade", selection: $psychoacoustic.fadeDurationSeconds) {
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("20 seconds").tag(20)
                        Text("30 seconds").tag(30)
                    }
                    .onChange(of: psychoacoustic.fadeDurationSeconds) { _ in
                        psychoacoustic.applyFadeDuration()
                    }
                    if let remaining = psychoacoustic.remainingSeconds {
                        HStack {
                            Text("Remaining")
                            Spacer()
                            Text(Self.formatCountdown(remaining))
                                .font(.headline.monospacedDigit())
                                .accessibilityIdentifier("psychoacoustic-countdown")
                        }
                        if let fadeRemaining = psychoacoustic.fadeRemainingSeconds {
                            Text("Fading out · \(Self.formatCountdown(fadeRemaining))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Timed sessions fade the generated tone and noise together over the selected ending. Headphone removal and manual Stop remain immediate.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .sheet(isPresented: $showingMiniMixer) {
                NavigationStack {
                    Form {
                        Section("Parallel-owned audio") {
                            ForEach(0..<5, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Text(Self.channelName(index)).font(.headline)
                                        Spacer()
                                        Button(mutedChannels.contains(index) ? "Unmute" : "Mute") {
                                            if mutedChannels.contains(index) {
                                                mutedChannels.remove(index)
                                            } else {
                                                mutedChannels.insert(index)
                                            }
                                            applyMiniMixer()
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("mixer-mute-\(index)")
                                        Button(soloChannels.contains(index) ? "Unsolo" : "Solo") {
                                            if soloChannels.contains(index) {
                                                soloChannels.remove(index)
                                            } else {
                                                soloChannels.insert(index)
                                            }
                                            applyMiniMixer()
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("mixer-solo-\(index)")
                                    }
                                    Slider(value: Binding(
                                        get: { channelTrims[index] },
                                        set: { value in
                                            channelTrims[index] = value
                                            applyMiniMixer()
                                        }
                                    ), in: 0...1)
                                        .accessibilityLabel("\(Self.channelName(index)) trim")
                                        .accessibilityIdentifier("mixer-trim-\(index)")
                                    Text("Trim \(Int(channelTrims[index] * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section("Experimental listening programs") {
                            Text("Specified acoustic sequences, not validated brain-state changes, treatment or performance enhancement. Stereo headphones are required.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(ExperimentalListeningProgram.allCases, id: \.self) { program in
                                Button(program.label) {
                                    psychoacoustic.chooseExperimentalProgram(program)
                                }
                                .disabled(psychoacoustic.isPlaying)
                            }
                            if let program = psychoacoustic.selectedProgram {
                                LabeledContent("Selected", value: program.label)
                                if let beat = psychoacoustic.programCurrentBeatHz {
                                    LabeledContent("Current stimulus difference",
                                        value: String(format: "%.1f Hz", beat))
                                }
                                Button("Clear program") {
                                    psychoacoustic.chooseExperimentalProgram(nil)
                                }
                                .disabled(psychoacoustic.isPlaying)
                            }
                            Link("Read scientific context", destination:
                                URL(string: "https://doi.org/10.1371/journal.pone.0335580")!)
                        }
                        Section {
                            Text("These controls affect only Parallel's three videos, metronome and generated stereo psychoacoustics. No third-party app volume or unmeasured master level is represented.")
                                .font(.footnote)
                        }
                    }
                    .navigationTitle("Mini Mixer")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingMiniMixer = false }
                        }
                    }
                    .onAppear(perform: applyMiniMixer)
                }
            }
        }
    }

    private static func channelName(_ index: Int) -> String {
        switch index {
        case 0: return "Video 1"
        case 1: return "Video 2"
        case 2: return "Video 3"
        case 3: return "Metronome"
        default: return "Psychoacoustic (tone + noise)"
        }
    }

    private func applyMiniMixer() {
        let levels = MiniMixerRouting.outputLevels(
            trims: channelTrims, muted: mutedChannels, solo: soloChannels
        )
        for index in 0..<3 {
            videos[index].mixerLevel = levels[index]
            videos[index].applyVolume()
        }
        model.mixerLevel = levels[3]
        model.applyGain()
        psychoacoustic.setMixerLevel(levels[4])
    }

    private static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func noiseSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: "\(Int(value.wrappedValue * 100))%")
            Slider(value: value, in: 0...0.2)
                .accessibilityLabel(title)
                .disabled(psychoacoustic.selectedProgram != nil)
        }
    }
}

/// Pure first-party mixer state reducer, independent of AVPlayer/AVAudioEngine.
enum MiniMixerRouting {
    static func outputLevels(trims: [Double], muted: Set<Int>, solo: Set<Int>) -> [Double] {
        guard trims.count == 5 else { return Array(repeating: 0, count: 5) }
        return trims.enumerated().map { index, trim in
            guard trim.isFinite, (0...1).contains(trim) else { return 0 }
            return muted.contains(index) || (!solo.isEmpty && !solo.contains(index))
                ? 0 : trim
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
            Toggle("+6 dB video boost", isOn: $media.boostedAudio)
                .font(.caption)
                .onChange(of: media.boostedAudio) { _ in
                    Task { @MainActor in await media.applyAudioBoost() }
                }
                .accessibilityIdentifier("media-boost-\(media.slot + 1)")
            Text("Optional linked-channel dynamics with conservative sample-peak guard. Not a calibrated true-peak limiter. Default is bypassed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
