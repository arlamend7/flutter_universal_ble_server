// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "universal_ble_server",
    platforms: [.macOS("10.11")],
    products: [.library(name: "universal-ble-server", targets: ["universal_ble_server"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .target(
            name: "universal_ble_server",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")],
            resources: [.process("PrivacyInfo.xcprivacy")]
        )
    ]
)
