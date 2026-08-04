// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Anvil",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AnvilCore", targets: ["AnvilCore"]),
        .executable(name: "anvild", targets: ["anvild"]),
        .executable(name: "anvil-watchdog", targets: ["anvil-watchdog"]),
        .executable(name: "AnvilApp", targets: ["AnvilApp"]),
        .executable(name: "anvil-selftest", targets: ["anvil-selftest"])
    ],
    targets: [
        .target(name: "AnvilCore"),
        .executableTarget(name: "anvild", dependencies: ["AnvilCore"]),
        .executableTarget(name: "anvil-watchdog", dependencies: ["AnvilCore"]),
        .executableTarget(name: "AnvilApp", dependencies: ["AnvilCore"]),
        .executableTarget(name: "anvil-selftest", dependencies: ["AnvilCore"]),
        .testTarget(name: "AnvilCoreTests", dependencies: ["AnvilCore"])
    ]
)
