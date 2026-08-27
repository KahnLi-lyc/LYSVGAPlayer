# LYSVGAPlayer

LYSVGAPlayer 计划提供一个面向现代 iOS 的原生 Swift SVGA 播放器。核心渲染基于 UIKit 与 Core Animation，SwiftUI 作为适配层提供。

> [!WARNING]
> 当前仓库仅完成 Swift Package、目录、依赖与并发编译规则的脚手架。播放器、格式解析、渲染、音频、缓存、导出等能力尚未实现，现阶段不能用于播放 SVGA 文件。

## 环境要求

- iOS 16.0 或更高版本
- Swift 6.0 或更高版本
- Xcode 16.0 或更高版本
- Swift Package Manager

Package 使用 Swift tools 6.0 与 Swift 6 语言模式，采用 Swift 6 默认的完整严格并发检查。当前依赖包括：

- [SwiftProtobuf](https://github.com/apple/swift-protobuf)，最低 1.27.0
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)，最低 0.9.19

## Package 状态

当前版本标识为 `0.1.0`，公开 Product、Target 与 Module 均命名为 `LYSVGAPlayer`。本阶段只公开 `LYSVGAVersion.identifier`，用于验证集成与模块导入。

以下逻辑模块已规划目录，但尚未提供实现：

- `Public`：公开 API 与版本信息
- `Format/Protobuf`：V1 ZIP/JSON、V2 zlib/Protobuf 格式识别与解析
- `Model`：不可变、可发送的统一视频模型
- `Loading`：资源加载、请求合并与缓存策略
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
- 不使用 Swift 6.2 及更高版本专属语法，保持 Swift 6.0 工具链兼容基线。

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

当前尚未发布可用播放器版本；上述代码仅说明计划中的 SPM 集成形式。

## 文档

架构边界、数据流与渲染层级见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## License

LYSVGAPlayer 使用 Apache License 2.0。上游归属说明见 [NOTICE](NOTICE)。
