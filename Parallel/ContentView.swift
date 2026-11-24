import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PsychoacousticDSP
import MetronomeEngine

struct ContentView: View {
    @ObservedObject var model: MetronomeViewModel
    let videos: [MediaMixerViewModel]
    @ObservedObject var pip: VideoPiPCoordinator
    @ObservedObject var psychoacoustic: PsychoacousticViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isDraggingTempo = false
    @State private var isDraggingCarrier = false
    @State private var isDraggingBeat = false
    @State private var isDraggingPsychoGain = false
    // First-party channel trim is independent of the original per-source controls.
    @State private var showingMiniMixer = false
    @State private var extraVideosExpanded = false
    @State private var fullScreenSelection: VideoFocusSelection?
    @State private var fullScreenDisplayingSlot: Int?
    @State private var metronomeExpanded = false
    @State private var psychoExpanded = false
    @State private var channelTrims: [Double] = Array(repeating: 1, count: 7)
    @State private var mutedChannels: Set<Int> = []
    @State private var soloChannels: Set<Int> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Video wall · MediaMixer") {
                    VStack(spacing: 12) {
                        MediaSlotCard(
                            media: videos[0], pip: pip,
                            foreground: scenePhase == .active,
                            fullScreenActiveSlot: fullScreenDisplayingSlot,
                            compact: false,
                            onFullScreen: { slot in fullScreenDisplayingSlot = slot; fullScreenSelection = VideoFocusSelection(slot: slot) }
                        )
                        HStack(alignment: .top, spacing: 10) {
                            MediaSlotCard(
                                media: videos[1], pip: pip,
                                foreground: scenePhase == .active,
                                fullScreenActiveSlot: fullScreenDisplayingSlot,
                                compact: true,
                                onFullScreen: { slot in fullScreenDisplayingSlot = slot; fullScreenSelection = VideoFocusSelection(slot: slot) }
                            )
                            MediaSlotCard(
                                media: videos[2], pip: pip,
                                foreground: scenePhase == .active,
                                fullScreenActiveSlot: fullScreenDisplayingSlot,
                                compact: true,
                                onFullScreen: { slot in fullScreenDisplayingSlot = slot; fullScreenSelection = VideoFocusSelection(slot: slot) }
                            )
                        }
                        DisclosureGroup(isExpanded: $extraVideosExpanded) {
                            HStack(alignment: .top, spacing: 10) {
                                MediaSlotCard(
                                    media: videos[3], pip: pip,
                                    foreground: scenePhase == .active,
                                    fullScreenActiveSlot: fullScreenDisplayingSlot,
                                    compact: true,
                                    onFullScreen: { slot in fullScreenDisplayingSlot = slot; fullScreenSelection = VideoFocusSelection(slot: slot) }
                                )
                                MediaSlotCard(
                                    media: videos[4], pip: pip,
                                    foreground: scenePhase == .active,
                                    fullScreenActiveSlot: fullScreenDisplayingSlot,
                                    compact: true,
                                    onFullScreen: { slot in fullScreenDisplayingSlot = slot; fullScreenSelection = VideoFocusSelection(slot: slot) }
                                )
                            }
                            Text("Videos 4 and 5 can keep playing even while this section is collapsed.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } label: {
                            HStack {
                                Label("Extra videos · 4 & 5", systemImage: "rectangle.stack")
                                Spacer()
                                Text("Optional")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("parallel-extra-videos-accordion")
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
                    Text("Seven independent Parallel audio sources: five videos, metronome and psychoacoustics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button {
                            withAnimation { metronomeExpanded.toggle() }
                        } label: {
                            HStack {
                                Label("Metronome", systemImage: "metronome")
                                Image(systemName: metronomeExpanded ? "chevron.up" : "chevron.down")
                            }
                        }
                        .accessibilityIdentifier("metronome-accordion")
                        Spacer()
                        Button(model.isPlaying ? "Stop" : "Play") {
                            model.togglePlayback()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("metronome-quick-transport")
                    }
                }
                if metronomeExpanded {
                Section("Clock Sync · Breathing") {
                    MetronomeClockPanel(model: model)
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


                }

                Section {
                    HStack {
                        Button {
                            withAnimation { psychoExpanded.toggle() }
                        } label: {
                            HStack {
                                Label("Psychoacoustics", systemImage: "waveform")
                                Image(systemName: psychoExpanded ? "chevron.up" : "chevron.down")
                            }
                        }
                        .accessibilityIdentifier("psychoacoustic-accordion")
                        Spacer()
                        Button(psychoacoustic.isPlaying ? "Stop" : "Play") {
                            psychoacoustic.togglePlayback()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("psychoacoustic-quick-transport")
                    }
                }
                if psychoExpanded {
                Section("PsychoacousticEngine") {
                    Text("Works with wired headphones, Bluetooth speakers/headsets and car audio. True binaural ear separation requires stereo headphones; car or mono playback may not produce a binaural illusion. No medical effects are implied.")
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
                         ? "Left/right carriers are separate in stereo. On car speakers or mono Bluetooth, the audio plays but the binaural illusion may not be heard; try monaural or isochronic mode."
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

                Section("Experimental listening programs") {
                    PsychoacousticProgramEditor(psychoacoustic: psychoacoustic)
                }
                Section("My psychoacoustic presets") {
                    PsychoacousticSoundPresetEditor(psychoacoustic: psychoacoustic)
                }
                Section("Scientific evidence") {
                    Button {
                        if let destination = URL(string:
                            "https://doi.org/10.1371/journal.pone.0286023") {
                            openURL(destination)
                        }
                    } label: {
                        Label("Review binaural-beat evidence", systemImage: "book.closed")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("psycho-evidence-review-only")
                    Text("Only this button opens the paper. Selecting programs, editing stages or removing them never opens a website.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Procedural noise layers") {
                    noiseSlider("White noise", value: $psychoacoustic.whiteNoise)
                    noiseSlider("Pink noise", value: $psychoacoustic.pinkNoise)
                    noiseSlider("Brown noise", value: $psychoacoustic.brownNoise)
                    Text("Original deterministic generators. Levels are capped at 20% and mixed through a digital peak limiter.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Presets and session") {
                    HStack {
                        Button("Focus") { psychoacoustic.applyPreset(.focus) }
                        Button("Calm") { psychoacoustic.applyPreset(.calm) }
                        Button("Rest") { psychoacoustic.applyPreset(.rest) }
                    }
                    if psychoacoustic.selectedProgram == nil {
                        if let custom = psychoacoustic.customSessionSeconds {
                            LabeledContent("Custom duration",
                                value: Self.formatCountdown(TimeInterval(custom)))
                            Text("Changing Stop after returns to a standard duration.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    } else {
                        LabeledContent("Program length", value:
                            Self.formatCountdown(TimeInterval(psychoacoustic.configuredSessionSeconds)))
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
            // A numeric BPM keyboard should never pin the Form to a focused
            // text field while live clock labels keep refreshing.
            .scrollDismissesKeyboard(.interactively)
            // One observer stays active whether the psychoacoustic accordion
            // is expanded or the Mini Mixer sheet is showing.
            .onChange(of: psychoacoustic.whiteNoise) { _ in psychoacoustic.applyLayers() }
            .onChange(of: psychoacoustic.pinkNoise) { _ in psychoacoustic.applyLayers() }
            .onChange(of: psychoacoustic.brownNoise) { _ in psychoacoustic.applyLayers() }
            .navigationTitle("Parallel")
            .fullScreenCover(item: $fullScreenSelection, onDismiss: {
                fullScreenDisplayingSlot = nil
            }) { selection in
                FullScreenVideoViewer(
                    videos: videos, selectedSlot: selection.slot,
                    onSelectionChange: { next in fullScreenDisplayingSlot = next }
                )
            }
            .sheet(isPresented: $showingMiniMixer) {
                NavigationStack {
                    Form {
                        Section("Parallel-owned audio") {
                            ForEach(0..<7, id: \.self) { index in
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
                        Section("Procedural noise layers") {
                            Text("Live independent white, pink and brown layers. All mix into the psychoacoustic source, not a separate AVPlayer.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            noiseSlider("White noise", value: $psychoacoustic.whiteNoise)
                            noiseSlider("Pink noise", value: $psychoacoustic.pinkNoise)
                            noiseSlider("Brown noise", value: $psychoacoustic.brownNoise)
                            Text("Changing a research-reference program's noise produces a modified experimental stimulus.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Section {
                            Text("These controls affect only Parallel's five videos, metronome and generated psychoacoustics. No third-party app volume or unmeasured master level is represented.")
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
        case 0..<5: return "Video \(index + 1)"
        case 5: return "Metronome"
        default: return "Psychoacoustic (tone + noise)"
        }
    }

    private func applyMiniMixer() {
        let levels = MiniMixerRouting.outputLevels(
            trims: channelTrims, muted: mutedChannels, solo: soloChannels
        )
        for index in videos.indices {
            videos[index].mixerLevel = levels[index]
            videos[index].applyVolume()
        }
        model.mixerLevel = levels[5]
        model.applyGain()
        psychoacoustic.setMixerLevel(levels[6])
    }

    private static func formatCountdown(_ seconds: TimeInterval) -> String {
        ParallelCountdownFormatter.clock(seconds)
    }

    private func noiseSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: "\(Int(value.wrappedValue * 100))%")
            Slider(value: value, in: 0...0.2)
                .accessibilityLabel(title)
        }
    }
}

/// Independent editing workspace. Controls are intentionally outside the
/// main Form's body to keep the three-video launch screen compact.
private struct PsychoacousticProgramEditor: View {
    @ObservedObject var psychoacoustic: PsychoacousticViewModel
    @State private var hours = "1"
    @State private var minutes = "0"
    @State private var seconds = "0"
    @State private var durationError: String?
    @State private var sequenceName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Research references keep their documented timing and carriers. Your editable programs are independent listening experiments, not EEG prescriptions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(ExperimentalListeningProgram.allCases, id: \.self) { program in
                Button {
                    psychoacoustic.chooseExperimentalProgram(program)
                } label: {
                    HStack {
                        Text(program.label)
                        Spacer()
                        if psychoacoustic.selectedProgram == program {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                }
                .disabled(psychoacoustic.isPlaying)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("listening-program-\(program.rawValue)")
            }
            if psychoacoustic.selectedProgram != nil {
                Button("Clear program · manual sound") {
                    psychoacoustic.chooseExperimentalProgram(nil)
                }
                .buttonStyle(.bordered)
                .disabled(psychoacoustic.isPlaying)
            }
            if psychoacoustic.selectedProgram == .threeStageArc {
                LabeledContent("Custom sequence duration",
                    value: Self.durationLabel(psychoacoustic.configuredSessionSeconds))
                ForEach(psychoacoustic.editableStages) { stage in
                    PsychoacousticStageEditor(psychoacoustic: psychoacoustic, stageID: stage.id)
                }
                Button {
                    psychoacoustic.addProgramStage()
                } label: {
                    Label("Add another stage", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(psychoacoustic.isPlaying)
                .accessibilityIdentifier("listening-stage-add")
                HStack {
                    TextField("Name this sequence", text: $sequenceName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        psychoacoustic.saveCustomSequence(name: sequenceName)
                        if psychoacoustic.errorMessage == nil { sequenceName = "" }
                    }
                    .buttonStyle(.bordered)
                    .disabled(psychoacoustic.isPlaying || sequenceName.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                }
                .accessibilityIdentifier("listening-sequence-save")
                Text("No fixed stage-count or 30-minute limit. Every stage can specify its own carrier and binaural difference. Longer sequences use more device resources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !psychoacoustic.savedSequences.isEmpty {
                DisclosureGroup("My saved sequences") {
                    ForEach(psychoacoustic.savedSequences) { saved in
                        HStack {
                            Button(saved.name) {
                                psychoacoustic.loadCustomSequence(id: saved.id)
                            }
                            .buttonStyle(.bordered)
                            .disabled(psychoacoustic.isPlaying)
                            Spacer()
                            Button(role: .destructive) {
                                psychoacoustic.deleteCustomSequence(id: saved.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(psychoacoustic.isPlaying)
                            .accessibilityLabel("Delete \(saved.name)")
                        }
                    }
                }
            }
            if psychoacoustic.selectedProgram == .threeStageArc ||
               psychoacoustic.selectedProgram == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom session length").font(.headline)
                    HStack {
                        TextField("Hours", text: $hours)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Session hours")
                        Text("h")
                        TextField("Minutes", text: $minutes)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Session minutes")
                        Text("m")
                        TextField("Seconds", text: $seconds)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Session seconds")
                        Text("s")
                    }
                    .textFieldStyle(.roundedBorder)
                    Button(psychoacoustic.selectedProgram == .threeStageArc
                           ? "Set length · distribute stages evenly"
                           : "Set custom session length") {
                        applyCustomDuration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(psychoacoustic.isPlaying)
                    .accessibilityIdentifier("listening-duration-distribute")
                    Text("Duration is split to the nearest second; extra seconds go to the first stages. Minimum 10 seconds per stage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("This reference keeps its fixed five-minute experimental stimulus. Select Editable sequence to adjust carrier notes, rates and timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let durationError {
                Text(durationError).font(.caption).foregroundStyle(.red)
            }
            if let difference = psychoacoustic.programCurrentBeatHz {
                LabeledContent("Current binaural difference",
                    value: String(format: "%.2f Hz", difference))
                LabeledContent("Current stimulus band", value:
                    PsychoacousticViewModel.bandLabel(for: difference))
            }
            Text("These are acoustic listening parameters, not measured EEG states.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func applyCustomDuration() {
        guard let h = Int(hours), let m = Int(minutes), let s = Int(seconds),
              h >= 0, h < (Int.max - 3599) / 3600,
              (0...59).contains(m), (0...59).contains(s) else {
            durationError = "Enter nonnegative hours and 0–59 minutes/seconds."
            return
        }
        let total = h * 3600 + m * 60 + s
        guard total >= 10 else {
            durationError = "Session must last at least 10 seconds."
            return
        }
        psychoacoustic.setCustomSessionDuration(seconds: total)
        durationError = nil
    }

    private static func durationLabel(_ value: Int) -> String {
        let h = value / 3600
        let m = (value % 3600) / 60
        let s = value % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}

private struct PsychoacousticStageEditor: View {
    @ObservedObject var psychoacoustic: PsychoacousticViewModel
    let stageID: UUID
    @State private var expanded = false

    var body: some View {
        if let stage = psychoacoustic.editableStages.first(where: { $0.id == stageID }),
           let index = psychoacoustic.editableStages.firstIndex(where: { $0.id == stageID }) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Stage length (seconds)",
                        value: Binding<Int>(
                            get: { stage.durationSeconds },
                            set: { psychoacoustic.updateProgramStage(
                                id: stageID, durationSeconds: $0) }),
                        format: .number)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(psychoacoustic.isPlaying)
                    Picker("Carrier input", selection: Binding<CarrierPitchTuning>(
                        get: { stage.tuning },
                        set: { psychoacoustic.updateProgramStage(id: stageID, tuning: $0) }
                    )) {
                        ForEach(CarrierPitchTuning.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(psychoacoustic.isPlaying)
                    if stage.tuning == .customA4Reference {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reference pitch · A4 (Hz)")
                                .font(.subheadline)
                            TextField("Custom A4 reference Hz",
                                value: Binding<Double>(
                                    get: { stage.referenceA4Hz },
                                    set: { psychoacoustic.updateProgramStage(
                                        id: stageID, referenceA4Hz: $0) }),
                                format: .number.precision(.fractionLength(0...2)))
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .disabled(psychoacoustic.isPlaying)
                                .accessibilityIdentifier("stage-a4-reference-\(index)")
                            Text("The entire twelve-note equal-temperament scale follows this A4 setting. E.g., A4 = 432 Hz makes B4 ≈ 484.9 Hz.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if stage.tuning == .manualHz {
                        TextField("Left carrier (Hz)",
                            value: Binding<Double>(
                                get: { stage.carrierHz },
                                set: { psychoacoustic.updateProgramStage(id: stageID, carrierHz: $0) }),
                            format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .disabled(psychoacoustic.isPlaying)
                            .accessibilityIdentifier("stage-carrier-hz-\(index)")
                    } else {
                        Picker("Musical note", selection: Binding<Int>(
                            get: { stage.noteClass },
                            set: { psychoacoustic.updateProgramStage(id: stageID, noteClass: $0) }
                        )) {
                            ForEach(0..<12, id: \.self) { pitchClass in
                                Text(CarrierPitchTuning.noteNames[pitchClass]).tag(pitchClass)
                                    .disabled(!stage.supports(note: pitchClass, octave: stage.octave))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(psychoacoustic.isPlaying)
                        Picker("Octave", selection: Binding<Int>(
                            get: { stage.octave },
                            set: { psychoacoustic.updateProgramStage(id: stageID, octave: $0) }
                        )) {
                            ForEach(0...5, id: \.self) { octave in
                                Text("Octave \(octave)")
                                    .tag(octave)
                                    .disabled(!stage.supports(note: stage.noteClass, octave: octave))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(psychoacoustic.isPlaying)
                        Text("C0–C5 are listed; out-of-range notes (including C0/C1) are disabled. This renderer only supports audible 100–800 Hz carriers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Binaural difference (Hz)",
                        value: Binding<Double>(
                            get: { stage.beatHz },
                            set: { psychoacoustic.updateProgramStage(id: stageID, beatHz: $0) }),
                        format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .disabled(psychoacoustic.isPlaying)
                        .accessibilityIdentifier("stage-beat-hz-\(index)")
                    LabeledContent("Left ear",
                        value: String(format: "%.2f Hz", stage.carrierHz))
                    LabeledContent("Right ear",
                        value: String(format: "%.2f Hz", stage.carrierHz + stage.beatHz))
                    LabeledContent("Stimulus band", value:
                        PsychoacousticViewModel.bandLabel(for: stage.beatHz))
                    Text("Delta / Theta / Alpha / Beta / Gamma describe the frequency difference, not your actual EEG state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Quartal tuning — coming soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove stage", role: .destructive) {
                        psychoacoustic.removeProgramStage(id: stageID)
                    }
                    .buttonStyle(.bordered)
                    .disabled(psychoacoustic.isPlaying || psychoacoustic.editableStages.count <= 1)
                    .accessibilityIdentifier("listening-stage-remove-\(index)")
                }
                .padding(.vertical, 6)
            } label: {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Stage \(index + 1)")
                            .font(.subheadline.bold())
                        Spacer()
                        Text(PsychoacousticViewModel.bandLabel(for: stage.beatHz))
                            .font(.caption.bold())
                    }
                    Text(String(format: "%.1f Hz beat · %.2f Hz carrier · %d:%02d",
                        stage.beatHz, stage.carrierHz,
                        stage.durationSeconds / 60, stage.durationSeconds % 60))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Saved snapshots of this audio engine only. Loading a snapshot never
/// changes the metronome, any AVPlayer, or immediately starts playback.
private struct PsychoacousticSoundPresetEditor: View {
    @ObservedObject var psychoacoustic: PsychoacousticViewModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save the current tone or sequence, carrier tuning, binaural difference, noise, level, mode, timer and fade. Presets restore at app launch without autoplay.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Name psycho preset", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    psychoacoustic.saveSoundPreset(name: name)
                    if psychoacoustic.errorMessage == nil { name = "" }
                }
                .buttonStyle(.borderedProminent)
                .disabled(psychoacoustic.isPlaying ||
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("psycho-preset-save")
            }
            ForEach(psychoacoustic.soundPresets) { preset in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            psychoacoustic.loadSoundPreset(id: preset.id)
                        } label: {
                            HStack {
                                Text(preset.name)
                                if psychoacoustic.selectedSoundPresetID == preset.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(psychoacoustic.isPlaying)
                        Spacer()
                        Button("Update") {
                            psychoacoustic.updateSoundPreset(id: preset.id)
                        }
                        .buttonStyle(.bordered)
                        .disabled(psychoacoustic.isPlaying)
                        Button(role: .destructive) {
                            psychoacoustic.deleteSoundPreset(id: preset.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(psychoacoustic.isPlaying)
                        .accessibilityLabel("Delete psycho preset \(preset.name)")
                    }
                    Text(preset.settings.selectedProgramRaw == "threeStageArc"
                        ? "Custom staged psychoacoustic session"
                        : preset.settings.selectedProgramRaw != nil
                          ? "Fixed acoustic comparison"
                          : "Manually configured psychoacoustics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Phase 4: concise controls first; optional analytical and cross-rhythm
/// tools stay behind a separate Advanced view. One shared model owns audio.
private struct MetronomeClockPanel: View {
    @ObservedObject var model: MetronomeViewModel
    @State private var tempoText = ""
    @State private var metronomePresetName = ""
    @State private var customChunkMinutesText = ""
    @State private var editingTempo = false
    @FocusState private var tempoFocused: Bool
    @FocusState private var chunkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Metronome view", selection: $model.clockSettings.advancedView) {
                Text("Simple").tag(false)
                Text("Advanced").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("p4-simple-advanced")
            Toggle("Sync metronome to real-world clock",
                   isOn: $model.clockSettings.clockSync)
                .accessibilityIdentifier("p4-clock-sync-toggle")
            Text("When enabled, Start joins the existing 24-hour clock grid. Time continues while stopped. Minute :00 has its own distinct chime.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading) {
                    Text("Tempo").font(.subheadline.bold())
                    Text(String(format: "%.3f BPM", model.bpm))
                        .font(.title3.monospacedDigit())
                }
                Spacer()
                Stepper("BPM", value: $model.bpm, in: 30...300, step: 0.5)
                    .labelsHidden()
            }
            HStack {
                Slider(value: $model.bpm, in: 30...300, step: 0.5,
                       onEditingChanged: { editing in
                           editingTempo = editing
                           if !editing { model.applyTempo() }
                       })
                    .accessibilityLabel("Metronome tempo")
                TextField("Custom BPM", text: $tempoText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .focused($tempoFocused)
                    .submitLabel(.done)
                    .onSubmit { tempoFocused = false }
                    .frame(width: 83)
                    .accessibilityIdentifier("p4-custom-bpm")
                Button("Set") {
                    guard let value = Double(tempoText), value.isFinite,
                          (30...300).contains(value) else { return }
                    // onChange applies it once; do not rebuild PCM twice.
                    model.bpm = (value * 1_000).rounded() / 1_000
                    tempoFocused = false
                }
                .buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Time signature").font(.subheadline.bold())
                    Spacer()
                    Picker("Numerator", selection: $model.clockSettings.meterNumerator) {
                        ForEach(1...32, id: \.self) { n in Text("\(n)").tag(n) }
                    }
                    .pickerStyle(.menu)
                    Text("/")
                    Picker("Denominator", selection: $model.clockSettings.meterDenominator) {
                        ForEach([1,2,4,8,16,32], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Stepper("Breathe in · \(model.clockSettings.inhaleCounts) counts",
                    value: $model.clockSettings.inhaleCounts, in: 1...256)
                    .tint(.blue)
                Stepper("Breathe out · \(model.clockSettings.exhaleCounts) counts",
                    value: $model.clockSettings.exhaleCounts, in: 1...256)
                    .tint(.teal)
            }
            .accessibilityIdentifier("p4-meter-breath")
            if let summary = model.minuteAnalysis {
                VStack(alignment: .leading, spacing: 7) {
                    Text("60-SECOND ANALYSIS").font(.caption.bold())
                        .foregroundStyle(.secondary)
                    LabeledContent("Measures", value:
                        "\(summary.fullMeasures) + \(number(summary.remainingMeterBeats)) beats")
                    LabeledContent("Breathing groups", value:
                        "\(summary.fullBreathingGroups) + \(number(summary.remainingBreathCounts)) counts")
                    LabeledContent("One breathing group", value:
                        String(format: "%.2f sec", summary.breathingSeconds))
                    if let alignment = summary.masterAlignmentMinutes {
                        LabeledContent("Full clock alignment", value:
                            "Every \(alignment) min")
                    } else {
                        LabeledContent("Full clock alignment", value:
                            "No exact recurrence forecast")
                    }
                    Text("Minute marker location depends on the continuous clock phase; live prediction appears below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if model.clockSettings.clockSync {
                TimelineView(.periodic(from: .now, by: tempoFocused ? 1.0 : 0.20)) { timeline in
                    minuteClock(at: timeline.date)
                }
                .transaction { $0.animation = nil }
                .accessibilityIdentifier("p4-live-minute-clock")
            } else {
                Text("Clock Sync off — original start-relative metronome is active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(model.isPlaying ? "Stop Metronome" : "Start Clock-Synced Metronome") {
                tempoFocused = false
                model.togglePlayback()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("metronome-transport")
            LabeledContent("Status",
                value: model.isPlaying ? "Metronome playing" :
                    (model.state == .interrupted ? "Interrupted" : "Metronome stopped"))
            Text(model.routeDescription)
                .font(.caption).foregroundStyle(.secondary)
            if model.clockSettings.advancedView {
                advancedControls
            }
        }
        .onChange(of: model.clockSettings) { _ in model.applyClockSettings() }
        .onChange(of: model.clockSettings.advancedView) { _ in
            tempoFocused = false
            chunkFocused = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    tempoFocused = false
                    chunkFocused = false
                }
            }
        }
        .onChange(of: model.bpm) { _ in
            if !editingTempo { model.applyTempo() }
        }
    }

    @ViewBuilder
    private var advancedControls: some View {
        Divider()
        Text("Advanced · Rhythm & Time Tracking").font(.headline)
        Picker("Breathing count unit", selection: $model.clockSettings.countDenominator) {
            ForEach([1,2,4,8,16,32], id: \.self) { value in
                Text("1/\(value) note").tag(value)
            }
        }
        Toggle("Reset breathing on each minute (opt-in)",
               isOn: $model.clockSettings.resetBreathingOnMinute)
        Toggle("Inhale/exhale transition tones", isOn: $model.clockSettings.breathCues)
        Slider(value: $model.clockSettings.breathCueVolume, in: 0...1)
            .accessibilityLabel("Breathing cue volume")
        Divider()
        Text("Three distinct clock cues").font(.subheadline.bold())
        Text("Minute = short high tick · Musical alignment = optional soft plonk · Time chunk complete = long one-second GO. If alignment and a chunk finish together, the GO replaces the optional plonk.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Time chunk complete · long GO",
               isOn: $model.clockSettings.supercycleCues)
            .accessibilityIdentifier("p4-time-chunk-go-toggle")
        Slider(value: $model.clockSettings.groupCueVolume, in: 0...1)
            .accessibilityLabel("Long GO volume")
        Toggle("Musical/clock alignment · short plonk",
               isOn: Binding<Bool>(
                   get: { model.clockSettings.alignmentCueEnabled ?? false },
                   set: { model.clockSettings.alignmentCueEnabled = $0 }
               ))
            .accessibilityIdentifier("p4-musical-alignment-cue-toggle")
        Slider(value: Binding<Double>(
            get: { model.clockSettings.alignmentCueVolume ?? 0.16 },
            set: { model.clockSettings.alignmentCueVolume = $0 }
        ), in: 0...0.6)
            .accessibilityLabel("Musical alignment plonk volume")
            .disabled(!(model.clockSettings.alignmentCueEnabled ?? false))
        Toggle("Distinct minute click", isOn: $model.clockSettings.markerEnabled)
        Slider(value: $model.clockSettings.markerVolume, in: 0...1)
            .accessibilityLabel("Minute marker level")
        LabeledContent("Minute marker volume",
            value: "\(Int(model.clockSettings.markerVolume * 100))%")
        Picker("Minute marker sound", selection: $model.clockSettings.markerVariant) {
            Text("High bell").tag(0)
            Text("Bright tick").tag(1)
            Text("Low chime").tag(2)
        }
        Picker("Additional rhythm", selection: $model.clockSettings.crossMode) {
            Text("None").tag(CrossRhythmMode.off)
            Text("Grouped polymeter").tag(CrossRhythmMode.grouped)
            Text("Ratio polyrhythm").tag(CrossRhythmMode.ratio)
        }
        if model.clockSettings.crossMode != .off {
            Slider(value: $model.clockSettings.crossCueVolume, in: 0...1)
                .accessibilityLabel("Cross rhythm cue volume")
        }
        if model.clockSettings.crossMode == .grouped {
            Stepper("Secondary group: \(model.clockSettings.crossGroup) quarter beats",
                value: $model.clockSettings.crossGroup, in: 2...64)
        } else if model.clockSettings.crossMode == .ratio {
            Stepper("Pulses: \(model.clockSettings.ratioPulses)",
                value: $model.clockSettings.ratioPulses, in: 2...16)
            Stepper("Over quarter beats: \(model.clockSettings.ratioDuration)",
                value: $model.clockSettings.ratioDuration, in: 2...32)
        }
        Divider()
        Text("Supercycle · Time chunks").font(.subheadline.bold())
        Picker("GO every", selection: $model.clockSettings.groupingMinutes) {
            ForEach([5, 10, 15, 30, 60], id: \.self) { n in
                Text("\(n) minutes").tag(n)
            }
            if ![5, 10, 15, 30, 60].contains(model.clockSettings.groupingMinutes) {
                Text("Custom · \(model.clockSettings.groupingMinutes) minutes")
                    .tag(model.clockSettings.groupingMinutes)
            }
        }
        .accessibilityIdentifier("p4-time-chunk-minute-picker")
        HStack(spacing: 8) {
            TextField("Custom minutes (1–1440)", text: $customChunkMinutesText)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .focused($chunkFocused)
                .accessibilityIdentifier("p4-custom-time-chunk-minutes")
            Button("Set") {
                guard let minutes = Int(customChunkMinutesText),
                      (1...1_440).contains(minutes) else { return }
                model.clockSettings.groupingMinutes = minutes
                chunkFocused = false
            }
            .buttonStyle(.bordered)
            .disabled(!(Int(customChunkMinutesText).map {
                (1...1_440).contains($0)
            } ?? false))
            .accessibilityIdentifier("p4-apply-custom-time-chunk")
        }
        Text("A long GO sounds only when this many minutes have elapsed. Clock origin follows fixed time blocks; Session Start counts from pressing Play.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("Block origin", selection: $model.clockSettings.blockAnchor) {
            Text("Real clock").tag(MinuteBlockAnchor.clock)
            Text("Session Start").tag(MinuteBlockAnchor.session)
        }
        Toggle("UTC (Zulu) clock display", isOn: $model.clockSettings.showUTC)
        if let summary = model.minuteAnalysis {
            LabeledContent("Musical/breath pattern period",
                value: summary.supercycleBeats.map {
                    String(format: "%.2f quarter beats", $0)
                } ?? "Not representable")
            LabeledContent("60-sec meter pulses",
                           value: String(format: "%.2f", summary.beatsPerMinute))
        }
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            advancedLive(at: timeline.date)
        }
        .transaction { $0.animation = nil }
        DisclosureGroup("My metronome presets") {
            VStack(alignment: .leading, spacing: 8) {
                Text("These save the clock, rhythm and breathing configuration only. Video and psychoacoustic presets remain independent.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Name metronome preset", text: $metronomePresetName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        model.saveClockPreset(name: metronomePresetName)
                        if model.errorMessage == nil { metronomePresetName = "" }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPlaying ||
                        metronomePresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("p4-metronome-preset-save")
                }
                ForEach(model.savedClockPresets) { preset in
                    HStack {
                        Button(preset.name) {
                            model.loadClockPreset(id: preset.id)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isPlaying)
                        if model.selectedClockPresetID == preset.id {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Spacer()
                        Button("Update") {
                            model.updateClockPreset(id: preset.id)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isPlaying)
                        Button(role: .destructive) {
                            model.deleteClockPreset(id: preset.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isPlaying)
                        .accessibilityLabel("Delete metronome preset \(preset.name)")
                    }
                }
            }
        }
        Text("Clock time is a mathematical reference. Built-in speaker, wired and Bluetooth output have different unmeasured latency. NTP correction is not required for offline use.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func minuteClock(at date: Date) -> some View {
        let unix = date.timeIntervalSince1970
        let current = ClockRhythmMath.minuteClock(at: unix)
        let localGroup = ClockRhythmMath.minuteWindow(
            atUnixSeconds: unix, bpm: model.bpm, settings: model.clockSettings)
        let boundary = (floor(unix / 60) + 1) * 60
        let beat = ClockRhythmMath.position(atUnixSeconds: boundary, bpm: model.bpm,
                                            settings: model.clockSettings)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(clockLabel(date))
                    .font(.title2.monospacedDigit().bold())
                Spacer()
                Text(model.clockSettings.showUTC ? "UTC" : "Local")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: current.elapsed, total: 60)
                .accessibilityLabel("Current minute progress")
            HStack {
                Text(String(format: "%.2f sec elapsed", current.elapsed))
                Spacer()
                Text(String(format: "%.2f until :00", current.untilNext))
            }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if let localGroup {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Breathing group")
                        .font(.subheadline)
                    Spacer(minLength: 5)
                    Text("Group \(localGroup.groupNumber) of \(localGroup.totalGroups)")
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .accessibilityIdentifier("p4-current-minute-breathing-group")
            }
            if let beat {
                HStack(spacing: 8) {
                    Text("Next :00 lands on")
                    Spacer(minLength: 5)
                    Text(ClockRhythmMath.meterBeatDescription(beat.beatInMeasure))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.caption)
                HStack(spacing: 8) {
                    Text("Breathing at :00")
                    Spacer(minLength: 5)
                    Text(breathingLabel(beat))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.caption)
            }
            Text("Minute chime always follows real :00; it never restarts the meter.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func advancedLive(at date: Date) -> some View {
        let unix = date.timeIntervalSince1970
        let position = ClockRhythmMath.position(atUnixSeconds: unix, bpm: model.bpm,
                                               settings: model.clockSettings)
        let window = ClockRhythmMath.minuteWindow(atUnixSeconds: unix, bpm: model.bpm,
                                                   settings: model.clockSettings)
        let summary = model.minuteAnalysis
        let next = summary?.masterAlignmentMinutes.flatMap {
            ClockRhythmMath.nextAlignment(after: unix, alignmentMinutes: $0)
        }
        let blockLength = Double(model.clockSettings.groupingMinutes) * 60
        let blockOrigin = model.clockSettings.blockAnchor == .session
            ? (model.clockSettings.sessionStartUnixSeconds ?? unix) : 0
        let blockElapsed = ClockRhythmMath.positiveRemainder(
            max(0, unix - blockOrigin), blockLength)
        return VStack(alignment: .leading, spacing: 6) {
            if let position {
                if let window {
                    HStack(spacing: 8) {
                        Text("Measure in this minute")
                        Spacer(minLength: 6)
                        Text("\(window.measureNumber) of \(window.totalMeasures)")
                            .monospacedDigit().bold()
                    }
                    .accessibilityIdentifier("p4-current-minute-measure")
                }
                HStack(spacing: 8) {
                    Text("Current beat")
                    Spacer(minLength: 6)
                    Text(ClockRhythmMath.meterBeatDescription(position.beatInMeasure))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(0..<model.clockSettings.meterNumerator, id: \.self) { beat in
                            Circle()
                                .fill(beat == Int(position.beatInMeasure) - 1
                                      ? Color.accentColor : Color.secondary.opacity(0.28))
                                .frame(width: 12, height: 12)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .accessibilityLabel("Current metrical beat visualization")
                if let window {
                    HStack(spacing: 8) {
                        Text("Breathing group this minute")
                        Spacer(minLength: 6)
                        Text("\(window.groupNumber) of \(window.totalGroups)")
                            .monospacedDigit().bold()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityIdentifier("p4-advanced-minute-group")
                }
                HStack(spacing: 8) {
                    Text("Breath phase")
                    Spacer(minLength: 6)
                    Text(breathingLabel(position))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                let totalCounts = Double(
                    model.clockSettings.inhaleCounts + model.clockSettings.exhaleCounts)
                ProgressView(value: max(0, min(totalCounts,
                    position.breathCountInGroup - 1)), total: totalCounts)
                    .tint(position.exhaling ? .teal : .blue)
                    .accessibilityLabel("Current inhale or exhale group progress")
            }
            if let next {
                HStack(spacing: 8) {
                    Text("Next musical–clock alignment")
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f sec", next))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                Text("Time chunk · GO")
                Spacer(minLength: 6)
                Text("\(Int(blockElapsed / 60) + 1) / \(model.clockSettings.groupingMinutes) min")
                    .monospacedDigit()
            }
            ProgressView(value: blockElapsed, total: blockLength)
                .accessibilityLabel("Time chunk progress")
            HStack(spacing: 8) {
                Text("Until long GO")
                Spacer(minLength: 6)
                Text(String(format: "%.1f sec", blockLength - blockElapsed))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clockLabel(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.clockSettings.showUTC
            ? TimeZone(secondsFromGMT: 0)! : .current
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let ms = Int(ClockRhythmMath.positiveRemainder(
            date.timeIntervalSince1970, 1) * 1000)
        return String(format: "%02d:%02d:%02d.%03d",
                      components.hour ?? 0, components.minute ?? 0,
                      components.second ?? 0, ms)
    }

    private func breathingLabel(_ position: RhythmPosition) -> String {
        // Position counts are cycle-relative; labels should count *within*
        // inhale or exhale instead (e.g. 4-in/8-out, cycle count 7 =
        // exhale count 3, not "exhale count 7").
        let phaseCount = position.exhaling
            ? position.breathCountInGroup - Double(model.clockSettings.inhaleCounts)
            : position.breathCountInGroup
        return "\(position.exhaling ? "Exhale" : "Inhale") count \(number(phaseCount))"
    }

    private func number(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.2f", value)
    }
}

/// Precise extended countdown without forcing 60+ minutes into MM:SS.
enum ParallelCountdownFormatter {
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0, seconds < TimeInterval(Int.max - 1) else {
            return "00:00"
        }
        let total = Int(ceil(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600,
                          (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Pure first-party mixer state reducer, independent of AVPlayer/AVAudioEngine.
enum MiniMixerRouting {
    static func outputLevels(trims: [Double], muted: Set<Int>, solo: Set<Int>) -> [Double] {
        guard trims.count == 7 else { return Array(repeating: 0, count: 7) }
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
// Fullscreen uses the ORIGINAL slot's AVPlayer, never a duplicate player.
// Changing the displayed slot is a view selection, not a transport command:
// other video audio, psychoacoustics and the metronome keep running.
struct VideoFocusSelection: Identifiable, Equatable {
    let slot: Int
    var id: Int { slot }
}

private struct FullScreenVideoViewer: View {
    let videos: [MediaMixerViewModel]
    let onSelectionChange: (Int) -> Void
    @State private var selectedSlot: Int
    @Environment(\.dismiss) private var dismiss

    init(videos: [MediaMixerViewModel], selectedSlot: Int,
         onSelectionChange: @escaping (Int) -> Void) {
        self.videos = videos
        self.onSelectionChange = onSelectionChange
        _selectedSlot = State(initialValue: selectedSlot)
    }

    private var loadedVideoIndices: [Int] {
        videos.indices.filter { videos[$0].hasVideo }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Video \(selectedSlot + 1) · Full Screen")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 5)
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("p5-fullscreen-close")
            }
            .padding(.horizontal)

            FullScreenPlayerControls(media: videos[selectedSlot])
                .id(selectedSlot)
                .frame(maxWidth: .infinity)

            HStack {
                Button {
                    selectAdjacent(-1)
                } label: {
                    Label("Previous video", systemImage: "chevron.left")
                }
                .disabled(loadedVideoIndices.count < 2)
                Spacer()
                Text("Switch the picture, not the playback")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    selectAdjacent(1)
                } label: {
                    Label("Next video", systemImage: "chevron.right")
                }
                .disabled(loadedVideoIndices.count < 2)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .accessibilityIdentifier("p5-fullscreen-prev-next")

            HStack(spacing: 7) {
                ForEach(videos.indices, id: \.self) { index in
                    Button("V\(index + 1)") {
                        changeSelection(to: index)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedSlot == index ? Color.accentColor : Color.secondary)
                    .disabled(!videos[index].hasVideo)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Show Video \(index + 1) in full screen")
                    .accessibilityIdentifier("p5-fullscreen-select-\(index + 1)")
                }
            }
            .padding(.horizontal)
            Spacer(minLength: 0)
            Text("Each video keeps its own audio, position, volume and playback state. PiP remains on Video 1.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding(.top, 12)
        .background(Color(.systemBackground))
        .accessibilityIdentifier("p5-fullscreen-viewer")
    }

    private func selectAdjacent(_ direction: Int) {
        let loaded = loadedVideoIndices
        guard loaded.count > 1, let index = loaded.firstIndex(of: selectedSlot) else { return }
        let next = (index + direction + loaded.count) % loaded.count
        changeSelection(to: loaded[next])
    }

    private func changeSelection(to slot: Int) {
        guard videos.indices.contains(slot), videos[slot].hasVideo else { return }
        onSelectionChange(slot) // Detach wall canvas before attaching fullscreen.
        selectedSlot = slot
    }
}

/// Observing only the selected model avoids re-rendering the fullscreen surface
/// at all five other players' progress-update intervals.
private struct FullScreenPlayerControls: View {
    @ObservedObject var media: MediaMixerViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var dragging = false
    @State private var scrubValue = 0.0

    var body: some View {
        VStack(spacing: 12) {
            VideoSurface(
                player: media.player,
                isForeground: scenePhase == .active,
                keepAttachedInBackground: false,
                onCanvasReady: nil
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            .accessibilityIdentifier("p5-fullscreen-video-\(media.slot + 1)")

            HStack(spacing: 10) {
                Button {
                    media.seek(to: media.currentSeconds - 10)
                } label: {
                    Label("Back 10 seconds", systemImage: "gobackward.10")
                }
                .accessibilityIdentifier("p5-fullscreen-back10")
                Spacer()
                Button {
                    media.togglePlayback()
                } label: {
                    Label(media.isPlaying ? "Pause" : "Play",
                          systemImage: media.isPlaying ? "pause.fill" : "play.fill")
                }
                .accessibilityIdentifier("p5-fullscreen-transport")
                Spacer()
                Button {
                    media.seek(to: media.currentSeconds + 10)
                } label: {
                    Label("Forward 10 seconds", systemImage: "goforward.10")
                }
                .accessibilityIdentifier("p5-fullscreen-forward10")
            }
            .buttonStyle(.bordered)
            .disabled(!media.hasVideo)

            if media.canSeek {
                Slider(
                    value: Binding(
                        get: { dragging ? scrubValue : media.currentSeconds },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(1, media.durationSeconds),
                    onEditingChanged: { editing in
                        if editing { scrubValue = media.currentSeconds }
                        else { media.seek(to: scrubValue) }
                        dragging = editing
                    }
                )
                .accessibilityLabel("Fullscreen Video \(media.slot + 1) timeline")
                .accessibilityIdentifier("p5-fullscreen-scrub")
                HStack {
                    Text(MediaMixerViewModel.formatTimestamp(
                        dragging ? scrubValue : media.currentSeconds))
                    Spacer()
                    Text(MediaMixerViewModel.formatTimestamp(media.durationSeconds))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack {
                Image(systemName: "speaker.wave.2.fill")
                Slider(value: $media.volume, in: 0...1)
                    .onChange(of: media.volume) { _ in media.applyVolume() }
                    .accessibilityLabel("Fullscreen Video \(media.slot + 1) volume")
            }
            Text(media.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal)
    }
}

private struct MediaSlotCard: View {
    @ObservedObject var media: MediaMixerViewModel
    @ObservedObject var pip: VideoPiPCoordinator
    let foreground: Bool
    let fullScreenActiveSlot: Int?
    let compact: Bool
    let onFullScreen: (Int) -> Void
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
                isForeground: foreground && fullScreenActiveSlot != media.slot,
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
            HStack(spacing: 7) {
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
                }
                Button {
                    onFullScreen(media.slot)
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .disabled(!media.hasVideo || (media.slot == 0 && (pip.isActive || pip.isStarting)))
                .accessibilityIdentifier("p5-fullscreen-open-\(media.slot + 1)")
            }
            if media.slot == 0, let pipError = pip.errorMessage {
                Text(pipError)
                    .font(.caption2)
                    .foregroundStyle(.red)
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
