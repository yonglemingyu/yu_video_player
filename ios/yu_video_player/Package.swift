// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// 核心包依赖：本地联调用 path，发布前必须切到远端 url。
//   tool/switch_core_dependency.sh remote   # 切到远端（发布前）
//   tool/switch_core_dependency.sh local    # 切回本地（联调）
let coreDependency: Package.Dependency = .package(url: "https://github.com/yonglemingyu/yu_video_player_ios.git", from: "1.0.0")

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
        // 第二个参数是 SwiftPM 由依赖 URL 推导出的 identity（仓库名小写），
        // 不是远端 Package.swift 里声明的 name: "YUVideoPlayerIOS"，写错会报
        // unknown package 'YUVideoPlayerIOS'。
        .product(name: "YUVideoPlayerIOS", package: "yu_video_player_ios")
      ]
    )
  ]
)
