import Foundation

public protocol OutputRouteStateProviding: AnyObject {
    var hasStereoHeadphones: Bool { get }
}

public final class MutableOutputRouteState: OutputRouteStateProviding, @unchecked Sendable {
    public var hasStereoHeadphones: Bool

    public init(hasStereoHeadphones: Bool) {
        self.hasStereoHeadphones = hasStereoHeadphones
    }
}

/// Injectable route policy around the pure renderer.
///
/// Route loss starts a deterministic fade and latches the source stopped.
/// Reconnection does not automatically resume; the future controller must
/// require an explicit user/session decision.
public struct RouteSafeStereoRenderer {
    private var renderer: StereoPCMRenderer
    private weak var routeState: OutputRouteStateProviding?
    private let routeLossFadeFrames: Int
    private var lastRouteAvailable: Bool
    private var framesUntilStop: Int?
    public private(set) var isStopped: Bool

    public init(
        renderer: StereoPCMRenderer,
        routeState: OutputRouteStateProviding,
        routeLossFadeFrames: Int
    ) {
        precondition(routeLossFadeFrames >= 0)
        self.renderer = renderer
        self.routeState = routeState
        self.routeLossFadeFrames = routeLossFadeFrames
        self.lastRouteAvailable = routeState.hasStereoHeadphones
        self.isStopped = !routeState.hasStereoHeadphones
    }

    /// Offline convenience method; the real-time path must be caller-owned.
    public mutating func render(frameCount: Int) -> StereoPCMBuffer {
        precondition(frameCount >= 0)
        var output = StereoPCMBuffer(frameCount: frameCount)
        output.left.withUnsafeMutableBufferPointer { left in
            output.right.withUnsafeMutableBufferPointer { right in
                render(into: left, right: right)
            }
        }
        return output
    }

    /// Research-only caller-owned-buffer route path. The route provider remains
    /// a same-thread test seam; a production render callback MUST receive route
    /// eligibility via a separately proven lock-free/atomic transport.
    public mutating func render(
        into left: UnsafeMutableBufferPointer<Float>,
        right: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(left.count == right.count)
        if isStopped {
            for i in 0..<left.count { left[i] = 0; right[i] = 0 }
            return
        }
        let available = routeState?.hasStereoHeadphones ?? false
        if lastRouteAvailable && !available {
            renderer.setGain(0, fadeFrames: routeLossFadeFrames)
            framesUntilStop = routeLossFadeFrames
        }
        lastRouteAvailable = available

        renderer.render(into: left, right: right)
        if let remaining = framesUntilStop {
            let next = max(0, remaining - left.count)
            framesUntilStop = next
            if next == 0 {
                isStopped = true
                framesUntilStop = nil
                if left.count > remaining {
                    for i in remaining..<left.count { left[i] = 0; right[i] = 0 }
                }
            }
        }
    }

}
