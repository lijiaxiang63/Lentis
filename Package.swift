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
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0"),
        // Sparkle 2.x — macOS software-update framework (auto download/install of
        // GitHub Release DMGs, EdDSA-signed). Distributed as a prebuilt binary
        // target (XCFramework); the only "native" dependency, bundled into the
        // .app by package_app.sh. See AGENTS.md "Auto-update (Sparkle)".
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.3")
    ],
    targets: [
        .executableTarget(
            name: "Lentis",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
