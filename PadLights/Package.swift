// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PadLights", platforms: [.macOS(.v13)], products: [.library(name: "PadLightProtocol", targets: ["PadLightProtocol"]), .executable(name: "padlights", targets: ["PadLights"])], targets: [.target(name: "NativeMIDI", linkerSettings: [.linkedFramework("CoreMIDI")]), .target(name: "PadLightProtocol"), .executableTarget(name: "PadLights", dependencies: ["PadLightProtocol", "NativeMIDI"]), .testTarget(name: "PadLightProtocolTests", dependencies: ["PadLightProtocol"])])
