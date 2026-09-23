// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "weft",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "weftd", targets: ["weftd"]),
        .executable(name: "weftctl", targets: ["weftctl"]),
        .executable(name: "weft-bar", targets: ["weft-bar"]),
    ],
    targets: [
        // C target: private SLS/CGS/AX symbols, resolved by name at load time
        // rather than linked, so a symbol a macOS update removes costs the
        // feature that uses it and never the launch. Nothing links SkyLight.
        // Public header is Sources/SkyLightShim/include/SkyLightShim.h
        .target(
            name: "SkyLightShim",
            publicHeadersPath: "include"
        ),
        // Pure: geometry + world model. No I/O, no AppKit, no SkyLight.
        .target(
            name: "WeftCore",
            dependencies: []
        ),
        // Platform: AX, SkyLight, spaces, displays. Behind protocols.
        .target(
            name: "WeftPlatform",
            dependencies: ["WeftCore", "SkyLightShim"]
        ),
        // Stubs for later milestones (M2/M6). Exist so the layout is final in M1.
        .target(name: "WeftConfig", dependencies: ["WeftCore", "WeftInput"]),
        // The Settings window's lossless weft.toml round-trip. Its own target
        // rather than a file inside weft-bar: it rewrites the user's config
        // file, and code that can eat a config file needs tests, which an
        // executable target cannot have.
        .target(name: "WeftBarConfig", dependencies: []),
        .target(name: "WeftInput", dependencies: ["WeftCore"]),
        .target(name: "WeftIPC", dependencies: ["WeftCore"]),
        .executableTarget(
            name: "weftd",
            dependencies: ["WeftCore", "WeftPlatform", "WeftConfig", "WeftInput", "WeftIPC"]
        ),
        .executableTarget(
            name: "weftctl",
            dependencies: [
                "WeftCore", "WeftPlatform", "WeftIPC", "WeftConfig",
                // For `config pin-workspaces`: the installers edit a config
                // the user has commented, and this is the only round-trip in
                // the tree that does not throw those comments away.
                "WeftBarConfig", "SkyLightShim",
            ]
        ),
        .executableTarget(
            name: "weft-bar",
            dependencies: [
                "WeftCore", "WeftPlatform", "WeftIPC", "WeftConfig",
                "WeftBarConfig", "SkyLightShim",
            ]
        ),
        .testTarget(
            name: "WeftCoreTests",
            dependencies: ["WeftCore"]
        ),
        .testTarget(
            name: "WeftInputTests",
            dependencies: ["WeftInput"]
        ),
        // The socket's shapes. weft-bar and weftctl parse these, and a field
        // that quietly changes meaning does not fail to decode — it decodes
        // into the wrong answer.
        .testTarget(
            name: "WeftIPCTests",
            dependencies: ["WeftIPC", "WeftCore"]
        ),
        .testTarget(
            name: "WeftConfigTests",
            dependencies: ["WeftConfig", "WeftCore", "WeftInput"]
        ),
        // The park ledger's file format. It is read once, after a crash, to
        // find windows nothing else in weft can see — so a shape that decodes
        // into the wrong answer does not show up as a decode failure, it shows
        // up as windows left at the corner of the screen.
        .testTarget(
            name: "WeftPlatformTests",
            dependencies: ["WeftPlatform", "WeftCore"]
        ),
        .testTarget(
            name: "WeftBarConfigTests",
            dependencies: ["WeftBarConfig"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
