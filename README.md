# LYSVGAPlayer

LYSVGAPlayer 计划提供一个面向现代 iOS 的原生 Swift SVGA 播放器。核心渲染基于 UIKit 与 Core Animation，SwiftUI 作为适配层提供。

> [!WARNING]
> 当前仓库已实现 SVGA V1/V2 格式解析、异步资源加载与内存/磁盘缓存，但渲染、播放时钟、音频调度和导出仍未实现，现阶段仍不能播放 SVGA 文件。

## 环境要求

- iOS 16.0 或更高版本
- Swift 6.2 或更高版本
- Xcode 26.0 或更高版本
- Swift Package Manager

Package 使用 Swift tools 6.2 与明确的 Swift 6 语言模式，采用 Swift 6 默认的完整严格并发检查。当前依赖包括：

- [SwiftProtobuf](https://github.com/apple/swift-protobuf)，最低 1.27.0
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)，最低 0.9.19

## Package 状态

当前版本标识为 `0.1.0`，公开 Product、Target 与 Module 均命名为 `LYSVGAPlayer`。公开 API 现包括不可变视频模型、`LYSVGASource`、`LYSVGACachePolicy`、`LYSVGAError` 与 `LYSVGAAssetLoader`。

当前已实现：

- `Public`：公开 API 与版本信息
- `Model`：不可变、可发送的统一视频模型
- `Format/Protobuf`：V1 ZIP/JSON、V2 zlib/Protobuf 格式识别、解压和统一模型映射
- `Loading`：Data、本地文件和远程 URL 加载、请求合并，以及受限内存 LRU/原始数据磁盘缓存

以下模块仍处于规划阶段：

- `Rendering`：Core Animation 图层树与逐帧渲染
- `Playback`：播放时钟、循环、范围、倍速与结束行为
- `Audio`：音频资源与时间线调度
- `SwiftUI`：`UIViewRepresentable` 与控制器适配
- `Export`：指定帧与 PNG 序列导出

这些目录属于同一个公开 Package Product，不会拆成额外公开 Product。

## 并发边界

- 视频、精灵、帧与形状等解析结果使用不可变 `Sendable` 值类型。
- 加载、请求合并与缓存由 actor 隔离。
- 解压与解析通过结构化并发执行，只跨边界传递 `Sendable` 数据。
- UIKit、`CALayer`、播放时钟、音频播放器和 Delegate 固定在 `MainActor`。
- Protobuf 生成对象不跨并发边界，解析后立即映射为包内值类型。
- 工具链基线为 Swift 6.2 / Xcode 26+；SwiftUI 适配层仍保持 iOS 16 运行时边界。

## Swift Package Manager 集成

在 Package 依赖中加入：

```swift
dependencies: [
    .package(
        url: "https://github.com/yichangli/LYSVGAPlayer.git",
        from: "0.1.0"
    ),
]
```

并在目标依赖中引用公开 Product：

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "LYSVGAPlayer", package: "LYSVGAPlayer"),
    ]
)
```

当前尚未发布可用播放器版本；上述代码仅说明 SPM 集成形式。格式读取可通过 `LYSVGAAssetLoader.load(_:cachePolicy:)` 使用，但返回模型暂时不能直接播放。

## 文档

架构边界、数据流与渲染层级见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## License

LYSVGAPlayer 使用 Apache License 2.0。上游归属说明见 [NOTICE](NOTICE)。
