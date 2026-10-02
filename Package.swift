// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuTidy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MenuTidy", targets: ["MenuTidy"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "MenuTidyCore"),
        .target(name: "MenuTidyDiagnosticInput", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "MenuTidy", dependencies: ["MenuTidyCore", "MenuTidyDiagnosticInput", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("ServiceManagement"), .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MenuTidyCoreTests", dependencies: ["MenuTidyCore"]),
        .testTarget(name: "MenuTidyAppTests", dependencies: ["MenuTidy", "MenuTidyCore"])
    ]
)
