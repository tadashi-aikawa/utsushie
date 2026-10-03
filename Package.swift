// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Utsushie",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Utsushie", targets: ["Utsushie"])],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
        // SDWebImage管理のBSD-3-Clauseパッケージ。Cソースから静的に同梱する。
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
        // Command Line Tools環境にもTesting内部モジュールを供給する。
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "0.12.0"),
    ],
    targets: [
        .target(name: "UtsushieCore", dependencies: ["TOMLKit"]),
        .executableTarget(name: "Utsushie", dependencies: ["UtsushieCore", .product(name: "libwebp", package: "libwebp-Xcode")]),
        .testTarget(name: "UtsushieCoreTests", dependencies: ["UtsushieCore", .product(name: "Testing", package: "swift-testing")]),
        .testTarget(name: "UtsushieAppTests", dependencies: ["Utsushie", .product(name: "Testing", package: "swift-testing")]),
    ]
)
