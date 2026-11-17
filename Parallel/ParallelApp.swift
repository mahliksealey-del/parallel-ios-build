import SwiftUI
import MetronomeEngine

// Single lifetime owner for all Parallel audio sources. The MediaMixer view
// model will receive this same session instance in a later phase.
@MainActor
final class ParallelAudioContainer: ObservableObject {
    let session: AudioSessionCoordinator
    let metronome: MetronomeViewModel

    init() {
        let engine = MetronomeEngine()
        let graph = AudioGraphCoordinator(metronome: engine)
        let coordinator = AudioSessionCoordinator(graph: graph)
        session = coordinator
        metronome = MetronomeViewModel(engine: engine, coordinator: coordinator)
    }
}

@main
struct ParallelApp: App {
    @StateObject private var audio = ParallelAudioContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(model: audio.metronome)
        }
    }
}
