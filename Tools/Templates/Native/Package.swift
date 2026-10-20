// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NookStarter", platforms: [.macOS(.v14)], products: [
    .executable(name: "ModuleApp", targets: ["ModuleApp"]),
    .executable(name: "PluginCheck", targets: ["PluginCheck"])
], dependencies: [.package(path: "Vendor/NookPluginSDK")], targets: [
    .target(name: "ModuleCore", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
    .executableTarget(name: "ModuleApp", dependencies: ["ModuleCore", .product(name: "NookPluginSDK", package: "NookPluginSDK")]),
    .executableTarget(name: "PluginCheck", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")]),
    .testTarget(name: "ModuleCoreTests", dependencies: ["ModuleCore"])
], swiftLanguageModes: [.v5])
