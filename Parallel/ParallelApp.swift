import SwiftUI
import MetronomeEngine

// App lifetime owns one audio session shared by the metronome and MediaMixer.
@MainActor
final class ParallelAudioContainer: ObservableObject {
    let session: AudioSessionCoordinator
    let metronome: MetronomeViewModel
    let media: MediaMixerViewModel

    init() {
        let engine = MetronomeEngine()
        let graph = AudioGraphCoordinator(metronome: engine)
        let coordinator = AudioSessionCoordinator(graph: graph)
        let video = MediaMixerViewModel(coordinator: coordinator)

        session = coordinator
        metronome = MetronomeViewModel(engine: engine, coordinator: coordinator)
        media = video

        coordinator.onSourceError = { [weak video] source, message in
            if source == .media(0) {
                video?.reportError(message)
            }
        }
    }
}

@main
struct ParallelApp: App {
    @StateObject private var audio = ParallelAudioContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(model: audio.metronome, media: audio.media)
        }
    }
}
