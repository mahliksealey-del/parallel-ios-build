import XCTest
@testable import PsychoacousticDSP

final class RouteSafetyTests: XCTestCase {
    func testMissingHeadphonesStartsStoppedAndSilent() {
        let route = MutableOutputRouteState(hasStereoHeadphones: false)
        let renderer = StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0.2
        )
        var safe = RouteSafeStereoRenderer(
            renderer: renderer,
            routeState: route,
            routeLossFadeFrames: 480
        )
        let output = safe.render(frameCount: 512)
        XCTAssertTrue(safe.isStopped)
        XCTAssertTrue(output.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(output.right.allSatisfy { $0 == 0 })
    }

    func testRouteLossFadesThenLatchesStopped() {
        let route = MutableOutputRouteState(hasStereoHeadphones: true)
        let renderer = StereoPCMRenderer(
            sampleRate: 48_000,
            leftFrequency: 200,
            rightFrequency: 210,
            gain: 0.2,
            initialPhase: .init(left: .pi / 2, right: .pi / 2)
        )
        var safe = RouteSafeStereoRenderer(
            renderer: renderer,
            routeState: route,
            routeLossFadeFrames: 480
        )
        _ = safe.render(frameCount: 64)
        route.hasStereoHeadphones = false
        let fading = safe.render(frameCount: 512)
        XCTAssertTrue(safe.isStopped)
        XCTAssertGreaterThan(abs(fading.left[0]), 0)
        XCTAssertEqual(fading.left[480], 0)
        XCTAssertTrue(fading.left[480...].allSatisfy { $0 == 0 })
        XCTAssertTrue(fading.right[480...].allSatisfy { $0 == 0 })

        route.hasStereoHeadphones = true
        let afterReconnect = safe.render(frameCount: 128)
        XCTAssertTrue(afterReconnect.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(afterReconnect.right.allSatisfy { $0 == 0 })
    }
    func testCallerOwnedRouteLossFadesAndStaysSilentAfterReconnect() {
        let route = MutableOutputRouteState(hasStereoHeadphones: true)
        let renderer = StereoPCMRenderer(
            sampleRate: 48_000, leftFrequency: 200, rightFrequency: 210,
            gain: 0.2, initialPhase: .init(left: .pi / 2, right: .pi / 2)
        )
        var safe = RouteSafeStereoRenderer(
            renderer: renderer, routeState: route, routeLossFadeFrames: 480
        )
        var left = [Float](repeating: 123, count: 512)
        var right = [Float](repeating: 123, count: 512)
        route.hasStereoHeadphones = false
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in safe.render(into: l, right: r) }
        }
        XCTAssertTrue(safe.isStopped)
        XCTAssertGreaterThan(abs(left[0]), 0)
        XCTAssertTrue(left[480...].allSatisfy { $0 == 0 })
        XCTAssertTrue(right[480...].allSatisfy { $0 == 0 })
        route.hasStereoHeadphones = true
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in safe.render(into: l, right: r) }
        }
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        XCTAssertTrue(right.allSatisfy { $0 == 0 })
    }

}
