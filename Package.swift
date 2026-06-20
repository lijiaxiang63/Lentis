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
        .target(
            name: "DCMTKWrapper",
            dependencies: [],
            cSettings: [
                .headerSearchPath("../../libs/dcmtk/include"),
                .headerSearchPath("../../libs/openjpeg/include/openjpeg-2.5")
            ],
            cxxSettings: [
                .headerSearchPath("../../libs/dcmtk/include"),
                .headerSearchPath("../../libs/openjpeg/include/openjpeg-2.5"),
                .define("DCMTK_BUILD_IN_PROGRESS")
            ],
            linkerSettings: [
                .unsafeFlags(["-Llibs/dcmtk/lib", "-Llibs/openjpeg/lib"]),
                .linkedLibrary("dcmimage"),
                .linkedLibrary("dcmimgle"),
                .linkedLibrary("dcmdata"),
                .linkedLibrary("oflog"),
                .linkedLibrary("ofstd"),
                .linkedLibrary("dcmjpeg"),
                .linkedLibrary("dcmjpls"),
                .linkedLibrary("dcmtkcharls"),
                .linkedLibrary("ijg8"),
                .linkedLibrary("ijg12"),
                .linkedLibrary("ijg16"),
                .linkedLibrary("oficonv"),
                .linkedLibrary("z"),
                .linkedLibrary("openjp2")
            ]
        ),
        .executableTarget(
            name: "Lentis",
            dependencies: ["DCMTKWrapper"]
        ),
        .testTarget(
            name: "OpenDicomViewerTests",
            dependencies: [
                "Lentis",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ]
)
