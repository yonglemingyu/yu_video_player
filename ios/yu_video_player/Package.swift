// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// 本地联调用 path（见 tool/switch_core_dependency.sh），发布前切回 url。
let coreDependency: Package.Dependency = .package(url: "https://github.com/yonglemingyu/yu_video_player_ios.git", from: "1.1.0")

let package = Package(
  name: "yu_video_player",
  platforms: [
    .iOS("15.0")
  ],
  products: [
    // Library names must not contain underscores.
    .library(name: "yu-video-player", targets: ["yu_video_player"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework"),
    coreDependency
  ],
  targets: [
    .target(
      name: "yu_video_player",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        // package 是 SwiftPM 由路径推导的 identity（仓库名小写），不是远端的 name: YUVideoPlayerIOS。
        .product(name: "YUVideoPlayerIOS", package: "yu_video_player_ios")
      ]
    )
  ]
)
