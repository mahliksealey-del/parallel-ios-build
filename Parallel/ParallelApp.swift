import SwiftUI
import MetronomeEngine

// App lifetime owns one audio session shared by the metronome and MediaMixer.
@MainActor
final class ParallelAudioContainer: ObservableObject {
    let session: AudioSessionCoordinator
    let metronome: MetronomeViewModel
    let psychoacoustic: PsychoacousticViewModel
    // App-owned array keeps five independent AVPlayers alive across scene changes.
    // The legacy "media" alias retains Video 1 identity from the validated build.
    let media: MediaMixerViewModel
    let videos: [MediaMixerViewModel]
    let pip: VideoPiPCoordinator

    init() {
        let engine = MetronomeEngine()
        let emergencyRelay = PsychoacousticEmergencyRelay()
        let graph = AudioGraphCoordinator(metronome: engine, emergencyRelay: emergencyRelay)
        let coordinator = AudioSessionCoordinator(
            graph: graph, emergencyRouteDisarm: {
                emergencyRelay.disarmImmediately()
            }
        )
        let slots = (0..<5).map { index in
            MediaMixerViewModel(coordinator: coordinator, slot: index)
        }

        session = coordinator
        metronome = MetronomeViewModel(engine: engine, coordinator: coordinator)
        psychoacoustic = PsychoacousticViewModel(graph: graph, coordinator: coordinator)
        media = slots[0]
        videos = slots
        pip = VideoPiPCoordinator()

        // A failure in one player must not overwrite the status of another.
        coordinator.onSourceError = { [weak self] source, message in
            guard let self else { return }
            switch source {
            case .media(let index) where self.videos.indices.contains(index):
                self.videos[index].reportError(message)
            case .psychoacoustic:
                self.psychoacoustic.reportError(message)
            default:
                break
            }
        }
    }
}

@main
struct ParallelApp: App {
    @StateObject private var audio = ParallelAudioContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(model: audio.metronome, videos: audio.videos,
                        pip: audio.pip, psychoacoustic: audio.psychoacoustic)
        }
    }
}
