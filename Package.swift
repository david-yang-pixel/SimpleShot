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
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
