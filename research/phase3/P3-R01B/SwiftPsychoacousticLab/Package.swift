// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftPsychoacousticLab",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "PsychoacousticDSP", targets: ["PsychoacousticDSP"]),
    ],
    targets: [
        .target(
            name: "P3AtomicControl",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PsychoacousticDSP",
            dependencies: ["P3AtomicControl"]
        ),
        .testTarget(
            name: "PsychoacousticDSPTests",
            dependencies: ["PsychoacousticDSP", "P3AtomicControl"]
        ),
    ]
)
