// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuTidy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MenuTidy", targets: ["MenuTidy"])],
    targets: [
        .target(name: "MenuTidyCore"),
        .executableTarget(name: "MenuTidy", dependencies: ["MenuTidyCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]),
        .testTarget(name: "MenuTidyCoreTests", dependencies: ["MenuTidyCore"])
    ]
)
