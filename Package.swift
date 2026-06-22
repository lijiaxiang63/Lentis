// swift-tools-version: 6.2
// Package.swift — Lentis
// Licensed under the MIT License. See LICENSE for details.

import PackageDescription

let package = Package(
    name: "Lentis",
    platforms: [
        // macOS 26 (Tahoe): required for the native Liquid Glass APIs
        // (glassEffect / GlassEffectContainer / .buttonStyle(.glass)).
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Lentis", targets: ["Lentis"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "Lentis",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "LentisTests",
            dependencies: [
                "Lentis",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ],
    // Keep the Swift 5 language mode: bumping the tools version to reach
    // .macOS(.v26) would otherwise default to the Swift 6 language mode, whose
    // strict concurrency checking is out of scope for this UI-only redesign.
    swiftLanguageModes: [.v5]
)
