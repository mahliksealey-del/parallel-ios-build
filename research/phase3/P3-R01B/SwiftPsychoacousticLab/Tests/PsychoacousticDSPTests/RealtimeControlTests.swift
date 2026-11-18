import Foundation
import XCTest
import P3AtomicControl
@testable import PsychoacousticDSP

final class RealtimeControlTests: XCTestCase {
    private func sampleBuffer(
        _ stream: inout RealtimeControlledStereoStream,
        frames: Int = 128
    ) -> ([Float], [Float]) {
        var left = [Float](repeating: 111, count: frames)
        var right = [Float](repeating: 111, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                stream.render(into: l, right: r)
            }
        }
        return (left, right)
    }

    private func renderer() -> StereoPCMRenderer {
        StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200, rightFrequency: 210,
            gain: 0.2,
            initialPhase: .init(left: .pi / 2, right: .pi / 2)
        )
    }

    func testFailClosedUnarmedAndNoSilentAutoStart() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        var stream = RealtimeControlledStereoStream(renderer: renderer(), control: owner.makeRenderPort())
        let (left, right) = sampleBuffer(&stream)
        XCTAssertTrue(stream.isStopped)
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        XCTAssertTrue(right.allSatisfy { $0 == 0 })
        owner.armAfterVerifiedStereoRoute()
        let (lateLeft, lateRight) = sampleBuffer(&stream)
        XCTAssertTrue(lateLeft.allSatisfy { $0 == 0 })
        XCTAssertTrue(lateRight.allSatisfy { $0 == 0 })
    }

    func testValidatedCommandsChangeOnlyRenderThreadOscillator() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        owner.armAfterVerifiedStereoRoute()
        var stream = RealtimeControlledStereoStream(renderer: renderer(), control: owner.makeRenderPort())
        XCTAssertTrue(owner.sendFrequencies(left: 240, right: 248, transitionFrames: 32))
        XCTAssertTrue(owner.sendGain(0.4, fadeFrames: 32))
        XCTAssertEqual(stream.currentFrequencies.left, 200)
        XCTAssertEqual(stream.currentGain, 0.2)
        let (left, right) = sampleBuffer(&stream, frames: 32)
        XCTAssertFalse(stream.isStopped)
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertTrue(right.allSatisfy(\.isFinite))
        XCTAssertEqual(stream.currentFrequencies.left, 240, accuracy: 1e-10)
        XCTAssertEqual(stream.currentFrequencies.right, 248, accuracy: 1e-10)
        XCTAssertEqual(stream.currentGain, 0.4, accuracy: 1e-10)
    }

    func testQueueFullSignalsFailureThenDrainsAndAcceptsMore() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        owner.armAfterVerifiedStereoRoute()
        for index in 0..<Int(P3_CONTROL_CAPACITY) {
            XCTAssertTrue(owner.sendGain(Double(index) / 100))
        }
        XCTAssertFalse(owner.sendGain(0.95), "Must reject overflow, not silently overwrite")
        var stream = RealtimeControlledStereoStream(renderer: renderer(), control: owner.makeRenderPort())
        _ = sampleBuffer(&stream, frames: 1)
        XCTAssertEqual(stream.currentGain, 0.63, accuracy: 1e-12)
        XCTAssertTrue(owner.sendGain(0.8))
        _ = sampleBuffer(&stream, frames: 1)
        XCTAssertEqual(stream.currentGain, 0.8, accuracy: 1e-12)
    }

    func testInvalidNumericInputsNeverEnterQueue() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        XCTAssertFalse(owner.sendGain(.nan))
        XCTAssertFalse(owner.sendGain(.infinity))
        XCTAssertFalse(owner.sendGain(-0.01))
        XCTAssertFalse(owner.sendGain(1.01))
        XCTAssertFalse(owner.sendGain(0.5, fadeFrames: -1))
        XCTAssertFalse(owner.sendFrequencies(left: .nan, right: 210))
        XCTAssertFalse(owner.sendFrequencies(left: -1, right: 210))
        XCTAssertFalse(owner.sendFrequencies(left: 200, right: 24_000))
        XCTAssertFalse(owner.sendFrequencies(left: 200, right: 210, transitionFrames: -1))
        owner.armAfterVerifiedStereoRoute()
        var stream = RealtimeControlledStereoStream(renderer: renderer(), control: owner.makeRenderPort())
        _ = sampleBuffer(&stream)
        XCTAssertEqual(stream.currentGain, 0.2)
        XCTAssertEqual(stream.currentFrequencies.left, 200)
    }

    func testEmergencyStopOverridesFullQueueAndDisallowsAutoResume() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        owner.armAfterVerifiedStereoRoute()
        var stream = RealtimeControlledStereoStream(renderer: renderer(), control: owner.makeRenderPort())
        let (before, _) = sampleBuffer(&stream, frames: 1)
        XCTAssertGreaterThan(abs(before[0]), 0)
        for _ in 0..<Int(P3_CONTROL_CAPACITY) {
            XCTAssertTrue(owner.sendGain(0.1))
        }
        owner.disarmImmediately()
        let (left, right) = sampleBuffer(&stream, frames: 512)
        XCTAssertTrue(stream.isStopped)
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        XCTAssertTrue(right.allSatisfy { $0 == 0 })
        owner.armAfterVerifiedStereoRoute()
        let (reconnect, _) = sampleBuffer(&stream, frames: 64)
        XCTAssertTrue(reconnect.allSatisfy { $0 == 0 })
    }

    func testNewExplicitSessionAllowedOnlyAfterArm() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        owner.armAfterVerifiedStereoRoute()
        var old = RealtimeControlledStereoStream(renderer: renderer(), control: owner.makeRenderPort())
        _ = sampleBuffer(&old, frames: 1)
        owner.disarmImmediately()
        _ = sampleBuffer(&old, frames: 1)
        XCTAssertTrue(old.isStopped)
        owner.armAfterVerifiedStereoRoute()
        var fresh = RealtimeControlledStereoStream(renderer: renderer(), control: owner.makeRenderPort())
        let (playing, _) = sampleBuffer(&fresh, frames: 1)
        XCTAssertFalse(fresh.isStopped)
        XCTAssertGreaterThan(abs(playing[0]), 0)
        let (oldMute, _) = sampleBuffer(&old, frames: 1)
        XCTAssertTrue(oldMute.allSatisfy { $0 == 0 })
    }

    func testDisarmGenerationAdvancesEveryTime() throws {
        let owner = try XCTUnwrap(RealtimeControlOwner(sampleRate: 48_000))
        let before = owner.gateSnapshot
        XCTAssertEqual(before & 1, 0)
        owner.armAfterVerifiedStereoRoute()
        XCTAssertEqual(owner.gateSnapshot & 1, 1)
        owner.disarmImmediately()
        let first = owner.gateSnapshot
        XCTAssertEqual(first & 1, 0)
        XCTAssertEqual(first >> 1, (before >> 1) + 1)
        owner.disarmImmediately()
        XCTAssertEqual(owner.gateSnapshot >> 1, (first >> 1) + 1)
    }

    func testAtomicSPSCStressPreservesAllCommandsInOrder() throws {
        let bus = try XCTUnwrap(p3_control_create())
        let total = 20_000
        let box = ReceiveBox(bus: bus)
        defer { p3_control_destroy(box.bus) }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var next = 0
            while next < total {
                var command = p3_control_command(
                    kind: 0, left_hz: 0, right_hz: 0,
                    gain: 0, transition_frames: 0
                )
                if p3_control_receive(box.bus, &command) {
                    if command.left_hz != Double(next) { box.inOrder = false }
                    next += 1
                }
            }
            box.received = next
            group.leave()
        }
        for i in 0..<total {
            let command = p3_control_command(
                kind: UInt32(P3_CONTROL_FREQUENCIES),
                left_hz: Double(i), right_hz: 0,
                gain: 0, transition_frames: 0
            )
            while !p3_control_send(box.bus, command) { /* test-only backpressure */ }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(box.received, total)
        XCTAssertTrue(box.inOrder)
    }
}

private final class ReceiveBox: @unchecked Sendable {
    // Written by consumer, only read by producer after DispatchGroup.wait().
    let bus: OpaquePointer
    init(bus: OpaquePointer) { self.bus = bus }
    var received: Int = 0
    var inOrder: Bool = true
}
