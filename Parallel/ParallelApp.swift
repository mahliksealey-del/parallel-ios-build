import SwiftUI
import MetronomeEngine

// App lifetime owns one audio session shared by the metronome and MediaMixer.
@MainActor
final class ParallelAudioContainer: ObservableObject {
    let session: AudioSessionCoordinator
    let metronome: MetronomeViewModel
    // App-owned array keeps three independent AVPlayers alive across scene changes.
    // The legacy "media" alias retains Video 1 identity from the validated build.
    let media: MediaMixerViewModel
    let videos: [MediaMixerViewModel]

    init() {
        let engine = MetronomeEngine()
        let graph = AudioGraphCoordinator(metronome: engine)
        let coordinator = AudioSessionCoordinator(graph: graph)
        let slots = (0..<3).map { index in
            MediaMixerViewModel(coordinator: coordinator, slot: index)
        }

        session = coordinator
        metronome = MetronomeViewModel(engine: engine, coordinator: coordinator)
        media = slots[0]
        videos = slots

        // A failure in one player must not overwrite the status of another.
        coordinator.onSourceError = { [weak self] source, message in
            guard case .media(let index) = source, let self,
                  self.videos.indices.contains(index) else { return }
            self.videos[index].reportError(message)
        }
    }
}

@main
struct ParallelApp: App {
    @StateObject private var audio = ParallelAudioContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(model: audio.metronome, videos: audio.videos)
        }
    }
}
