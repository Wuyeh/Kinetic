// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KineticSceneRuntime",
    platforms: [.macOS(.v13)],
    products: [.library(name: "KineticSceneRuntime", targets: ["KineticSceneRuntime"])],
    targets: [
        // Third-party copyright and MIT terms are retained with the engine sources.
        // See NOTICE.md and Sources/KineticWPEEngine/UPSTREAM_LICENSE.txt.
        .target(name: "KineticWPEEngine", exclude: ["UPSTREAM_LICENSE.txt"],
                resources: [.process("Engine/Runtime/Metal/WPEMetalBuiltins.metal")]),
        .target(name: "KineticSceneRuntime", dependencies: ["KineticWPEEngine"]),
        .testTarget(name: "KineticSceneRuntimeTests", dependencies: ["KineticSceneRuntime"]),
        .testTarget(name: "KineticWPEEngineTests", dependencies: ["KineticWPEEngine"])
    ]
)
