// swift-tools-version:5.9
import PackageDescription

// Platform-neutral logic shared by the iPhone app and the Mac relay.
// Foundation only, so the whole package builds and tests on Linux as well.
let package = Package(
    name: "ReminderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReminderCore", targets: ["ReminderCore"]),
    ],
    targets: [
        .target(name: "ReminderCore"),
        .testTarget(name: "ReminderCoreTests", dependencies: ["ReminderCore"]),
    ]
)
