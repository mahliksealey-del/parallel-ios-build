import SwiftUI

@main
struct ParallelApp: App {
    @StateObject private var metronome = MetronomeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: metronome)
        }
    }
}
