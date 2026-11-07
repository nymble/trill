// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-only
//
// TrillKit: protocol codec, MIDI monitor model, presets, UF2 validation and
// (on Apple platforms) the CoreMIDI adapter shared by the Trill Mac and iOS
// apps. Only Apple system frameworks; no third-party dependencies.
import PackageDescription

let package = Package(
    name: "TrillKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TrillKit", targets: ["TrillKit"]),
    ],
    targets: [
        .target(name: "TrillKit"),
        .testTarget(name: "TrillKitTests", dependencies: ["TrillKit"]),
    ]
)
