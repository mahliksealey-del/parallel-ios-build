import SwiftUI

struct ContentView: View {
    @ObservedObject var model: MetronomeViewModel

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Playback") {
                    Button(model.isPlaying ? "Stop Metronome" : "Start Metronome") { model.togglePlayback() }
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
            .navigationTitle("Parallel Metronome")
        }
    }
}

#Preview {
    ContentView(model: MetronomeViewModel())
}
