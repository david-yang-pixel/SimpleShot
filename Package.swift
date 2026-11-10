// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleShot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SimpleShot",
            path: "Sources/SimpleShot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("SwiftUI"),
                // Translation 框架在 macOS 15 才有，弱链接以便 macOS 14 也能启动
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "Translation"]),
            ]
        )
    ]
)
