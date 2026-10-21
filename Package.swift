// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QCYBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "QCYBar", path: "Sources/QCYBar"),
        .testTarget(name: "QCYBarTests", dependencies: ["QCYBar"], path: "Tests/QCYBarTests"),
    ]
)
