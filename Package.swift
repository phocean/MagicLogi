// swift-tools-version:5.10
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste

import PackageDescription

let package = Package(
    name: "magiclogi",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: HID++ framing and payload parsing, configuration,
        // button/scroll decisions. No IOKit, no CoreGraphics: unit-tested.
        .target(name: "MagicLogiCore"),
        // The single executable: daemon + diagnostic subcommands.
        .executableTarget(
            name: "magiclogid",
            dependencies: ["MagicLogiCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embedded Info.plist: gives the binary a bundle identifier and
                // a name for the macOS privacy (TCC) prompts and lists.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/magiclogid/Info.plist"]),
                .linkedFramework("IOKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "MagicLogiCoreTests", dependencies: ["MagicLogiCore"]),
    ]
)
