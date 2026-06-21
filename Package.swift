// swift-tools-version: 5.9
// Package.swift — Lentis
// Licensed under the MIT License. See LICENSE for details.

import PackageDescription

let package = Package(
    name: "Lentis",
    platforms: [
        .macOS(.v14)
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
    ]
)
