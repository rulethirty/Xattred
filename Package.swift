// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Xattred",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Xattred", targets: ["Xattred"])],
    targets: [
        .target(name: "XattredCore"),
        .executableTarget(name: "Xattred", dependencies: ["XattredCore"]),
        .executableTarget(name: "XattredCoreTests", dependencies: ["XattredCore"], path: "Tests/XattredCoreTests")
    ]
)