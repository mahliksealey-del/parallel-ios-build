# Parallel public build snapshot

This repository is a minimal, self-contained build snapshot of the Parallel Phase 1 iPhone metronome. It contains the application target, independent `MetronomeEngine` framework, XCTest targets, Xcode project metadata, unsigned packaging script, and a manually dispatched public build workflow.

## Build policy

- The workflow runs only through **Actions → Parallel Public iOS Build → Run workflow**.
- It uses the standard `macos-15` runner and Xcode 16.4 with a 20-minute timeout.
- Repository permissions are read-only and third-party actions are pinned to immutable commit SHAs.
- Tests run on the iOS Simulator before an unsigned ARM64 device build is packaged.
- The generated app is checked for its architecture, unsigned state, bundle identifier, and `UIBackgroundModes` audio entry.
- `Parallel-unsigned.ipa` is a signing input, not an installable application. No credentials or signing assets belong in this repository.
- The uploaded artifact includes build provenance and the IPA SHA-256 and expires after seven days.

## Local limitations

Windows can audit the project structure but cannot compile native iOS code. Xcode compilation is authoritative. Simulator success does not validate background playback, cross-app mixing, Bluetooth behavior, interruptions, timing, signing, installation, or physical-iPhone behavior.

## Source and licensing

No third-party source packages, media assets, or copied open-source implementation code are included. Publication of source code does not itself grant a software license. No permission to use, modify, or redistribute this code is granted unless the copyright owner adds an explicit license later.
