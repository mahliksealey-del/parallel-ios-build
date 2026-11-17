import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: MetronomeViewModel
    let videos: [MediaMixerViewModel]
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Video wall · MediaMixer") {
                    VStack(spacing: 12) {
                        // Always show all three live displays together when
                        // Parallel is active. Video 1 is reserved for future PiP.
                        MediaSlotCard(media: videos[0], foreground: scenePhase == .active,
                                      compact: false)
                        HStack(alignment: .top, spacing: 10) {
                            MediaSlotCard(media: videos[1], foreground: scenePhase == .active,
                                          compact: true)
                            MediaSlotCard(media: videos[2], foreground: scenePhase == .active,
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
                    Slider(value: $model.bpm, in: 30...300, step: 1)
                        .disabled(!model.canEditTempo)
                        .accessibilityLabel("Tempo")
                        .accessibilityValue("\(Int(model.bpm)) beats per minute")
                }
                .onChange(of: model.bpm) { _ in model.applyTempo() }

                Section("Metronome level") {
                    Slider(value: $model.gain, in: 0...1)
                        .accessibilityLabel("Metronome level")
                    Text("Independent linear gain: \(Int(model.gain * 100))%")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: model.gain) { _ in model.applyGain() }

                Section("Metronome playback") {
                    Button(model.isPlaying ? "Stop Metronome" : "Start Metronome") {
                        model.togglePlayback()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("metronome-transport")
                    LabeledContent("Status", value: model.state.label)
                    Text(model.routeDescription).font(.footnote).foregroundStyle(.secondary)
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
    let foreground: Bool
    let compact: Bool
    @State private var showingFileImporter = false

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

            VideoSurface(player: media.player, isForeground: foreground)
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
                .disabled(media.isImporting)
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

    func makeUIView(context: Context) -> PlayerCanvas {
        PlayerCanvas()
    }

    func updateUIView(_ view: PlayerCanvas, context: Context) {
        view.updatePresentation(player: player, isForeground: isForeground)
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

#Preview {
    let audio = ParallelAudioContainer()
    ContentView(model: audio.metronome, videos: audio.videos)
}
