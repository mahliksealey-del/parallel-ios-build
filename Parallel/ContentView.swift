import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: MetronomeViewModel
    @ObservedObject var media: MediaMixerViewModel
    @State private var showingFileImporter = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Video 1 · MediaMixer") {
                    VideoSurface(player: media.player, isForeground: scenePhase == .active)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("media-preview-1")

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label(media.hasVideo ? "Replace video" : "Import video from Files",
                              systemImage: "folder.badge.plus")
                    }
                    .disabled(media.isImporting)
                    .accessibilityIdentifier("media-import-1")

                    Text(media.fileName)
                        .lineLimit(2)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if media.isImporting {
                        ProgressView("Importing and checking video...")
                    }

                    Button(media.isPlaying ? "Pause Video" : "Play Video") {
                        media.togglePlayback()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!media.hasVideo || media.isImporting)
                    .accessibilityIdentifier("media-transport-1")

                    Slider(value: $media.volume, in: 0...1)
                        .onChange(of: media.volume) { _ in media.applyVolume() }
                        .accessibilityLabel("Video 1 volume")
                    Text("Video level: \(Int(media.volume * 100))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Video status", value: media.status)
                }

                if let error = media.errorMessage {
                    Section("Video problem") {
                        Text(error).foregroundStyle(.red)
                    }
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
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.movie]
            ) { result in
                switch result {
                case .success(let url):
                    Task { @MainActor in await media.importVideo(from: url) }
                case .failure(let error):
                    Task { @MainActor in media.reportError(error.localizedDescription) }
                }
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
    ContentView(model: audio.metronome, media: audio.media)
}
