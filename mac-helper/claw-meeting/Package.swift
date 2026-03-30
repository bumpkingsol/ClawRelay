// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClawMeeting",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.4"),
    ],
    targets: [
        .executableTarget(
            name: "ClawMeeting",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/ClawMeeting"
        ),
        .testTarget(
            name: "ClawMeetingTests",
            dependencies: ["ClawMeeting"],
            path: "Tests/ClawMeetingTests"
        ),
    ]
)
