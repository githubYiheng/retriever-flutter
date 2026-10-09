// swift-tools-version: 5.9
// Retriever Flutter 插件的 iOS 垫片（SwiftPM 路径；Flutter 3.44 模板：依赖 FlutterFramework、隐私清单 .process）。
// CocoaPods 路径见 ../revdog_retriever.podspec（两条路径同一份源码；官方要求插件在另行通知前同时支持两者）。

import PackageDescription

let package = Package(
    name: "revdog_retriever",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "revdog-retriever", targets: ["revdog_retriever"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "revdog_retriever",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
