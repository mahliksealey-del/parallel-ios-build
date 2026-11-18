import Foundation
import P3AtomicControl

/// The owning, NON-real-time side of a bounded, single-producer control bus.
/// Create and destroy while the audio callback is suspended. Producer calls
/// must be serialized on ONE designated control queue, never made concurrently
/// from arbitrary UI/event threads. Disarm is the one multi-thread-safe bypass.
/// A render port does not retain this owner: owner must outlive render callbacks.
public final class RealtimeControlOwner: @unchecked Sendable {
    private let storage: OpaquePointer
    private let sampleRate: Double

    public init?(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        guard let allocated = p3_control_create() else { return nil }
        storage = allocated
        self.sampleRate = sampleRate
    }

    deinit { p3_control_destroy(storage) }

    /// The resulting non-owning value is safe to *read* only while this owner
    /// is alive. Do not create or destroy it from the render callback.
    public func makeRenderPort() -> RealtimeControlRenderPort {
        RealtimeControlRenderPort(storage: storage)
    }

    /// One producer, bounded capacity (64), false on full. Never drops a
    /// command silently. Only validated numeric values enter the render path.
    @discardableResult
    public func sendFrequencies(
        left: Double, right: Double, transitionFrames: Int = 0
    ) -> Bool {
        guard left.isFinite, right.isFinite, left >= 0, right >= 0,
              left < sampleRate / 2, right < sampleRate / 2,
              transitionFrames >= 0, transitionFrames <= Int(UInt32.max)
        else { return false }
        let command = p3_control_command(
            kind: UInt32(P3_CONTROL_FREQUENCIES), left_hz: left,
            right_hz: right, gain: 0,
            transition_frames: UInt32(transitionFrames)
        )
        return p3_control_send(storage, command)
    }

    @discardableResult
    public func sendGain(_ gain: Double, fadeFrames: Int = 0) -> Bool {
        guard gain.isFinite, gain >= 0, gain <= 1,
              fadeFrames >= 0, fadeFrames <= Int(UInt32.max)
        else { return false }
        let command = p3_control_command(
            kind: UInt32(P3_CONTROL_GAIN), left_hz: 0,
            right_hz: 0, gain: gain,
            transition_frames: UInt32(fadeFrames)
        )
        return p3_control_send(storage, command)
    }

    /// CONTROL QUEUE ONLY: require the higher-level iOS route policy to first
    /// verify stereo headphones. This API does not detect physical routes.
    public func armAfterVerifiedStereoRoute() { p3_control_arm(storage) }

    /// ROUTE NOTIFICATION THREAD: independent atomic emergency kill switch.
    /// The same stream can NEVER resume after disarm, even if rearmed.
    public func disarmImmediately() { p3_control_disarm(storage) }

    public var gateSnapshot: UInt64 { p3_control_gate_snapshot(storage) }
}

/// Non-owning raw C11 atomic mailbox read port. Used on exactly ONE audio
/// callback/render thread, never shared between concurrent render instances.
/// No Swift objects, weak references, queues, locks, or ARC are traversed in
/// the hot path; the owner must remain alive until all callbacks are stopped.
public struct RealtimeControlRenderPort: @unchecked Sendable {
    fileprivate let storage: OpaquePointer

    fileprivate init(storage: OpaquePointer) { self.storage = storage }

    public var gateSnapshot: UInt64 { p3_control_gate_snapshot(storage) }

    fileprivate func dequeue() -> p3_control_command? {
        var result = p3_control_command(
            kind: 0, left_hz: 0, right_hz: 0, gain: 0,
            transition_frames: 0
        )
        return p3_control_receive(storage, &result) ? result : nil
    }
}

/// Offline/live-adapter *candidate*. No AVAudioEngine dependency.
/// Gate loss always immediately silences the complete returned buffer and
/// permanently latches this stream stopped. New verified user/session action
/// and a *new* stream are required to resume, never an automatic reconnect.
///
/// This is NOT a full production real-time safety proof. It checks the gate
/// before and after rendering (not during hardware transfer). An OS route
/// switch can beat notifications and output-buffer delivery; physical-device
/// verification and iOS audio-session policy are still mandatory.
public struct RealtimeControlledStereoStream {
    private var renderer: StereoPCMRenderer
    private let control: RealtimeControlRenderPort
    private let initialGeneration: UInt64
    public private(set) var isStopped: Bool

    public init(renderer: StereoPCMRenderer, control: RealtimeControlRenderPort) {
        self.renderer = renderer
        self.control = control
        let gate = control.gateSnapshot
        initialGeneration = gate >> 1
        isStopped = (gate & 1) == 0
    }

    public var phaseSnapshot: RendererPhaseSnapshot { renderer.phaseSnapshot }
    public var currentFrequencies: (left: Double, right: Double) { renderer.currentFrequencies }
    public var currentGain: Double { renderer.currentGain }

    public mutating func render(
        into left: UnsafeMutableBufferPointer<Float>,
        right: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(left.count == right.count)
        if isStopped || !isGateValid {
            isStopped = true
            Self.zero(left, right)
            return
        }

        // Bound per-buffer control work even if a producer continuously
        // replenishes the queue while we render. Acquire/release ring
        // operations guarantee that each POD command is fully published.
        for _ in 0..<Int(P3_CONTROL_CAPACITY) {
            guard let command = control.dequeue() else { break }
            switch command.kind {
            case UInt32(P3_CONTROL_FREQUENCIES):
                renderer.setFrequencies(
                    left: command.left_hz, right: command.right_hz,
                    transitionFrames: Int(command.transition_frames)
                )
            case UInt32(P3_CONTROL_GAIN):
                renderer.setGain(command.gain, fadeFrames: Int(command.transition_frames))
            default:
                // The bus is private and only the validated owner publishes
                // commands. Unknown commands must not mutate oscillator state.
                continue
            }
        }

        if !isGateValid {
            isStopped = true
            Self.zero(left, right)
            return
        }
        renderer.render(into: left, right: right)
        if !isGateValid {
            // If lost during synthesis, sanitize all generated samples before
            // returning the buffer to the future audio adapter.
            isStopped = true
            Self.zero(left, right)
        }
    }

    private var isGateValid: Bool {
        let gate = control.gateSnapshot
        return (gate & 1) != 0 && gate >> 1 == initialGeneration
    }

    private static func zero(
        _ left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>
    ) {
        for frame in 0..<left.count { left[frame] = 0; right[frame] = 0 }
    }
}
