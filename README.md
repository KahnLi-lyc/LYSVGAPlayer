# LYSVGAPlayer

LYSVGAPlayer 是面向 iOS 16 及后续系统的原生 Swift SVGA 播放器。它使用 UIKit、Core Animation 与 AVFoundation 实现播放内核，并提供 iOS 16 可用的 SwiftUI 适配层。

当前开发版本为 `0.1.0`，已经具备 V1/V2 解析、加载缓存、位图/矢量/matte 渲染、播放控制、内嵌音频、动态内容、SwiftUI 和帧导出能力。公开样例已经通过自动测试与 Demo 模拟器播放；上游性能对照和业务素材验收仍需在统一环境完成，因此本项目暂不宣称已经覆盖所有生产 SVGA 文件或绝对优于其他实现。

## 环境要求

- iOS 16.0 或更高版本
- Swift 6.2 或更高版本
- Xcode 26.0 或更高版本
- Swift Package Manager

Package 使用 Swift tools 6.2、Swift 6 语言模式与 Swift 6 默认的完整并发检查。依赖包括：

- [SwiftProtobuf](https://github.com/apple/swift-protobuf)，最低 1.27.0
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)，最低 0.9.19

## 已实现能力

- SVGA 1.x ZIP/JSON 与 2.x zlib/Protobuf 识别、解压、校验和统一模型映射
- `Data`、Bundle、文件、HTTP(S) 与完整 `URLRequest` 加载，相同请求合并、取消、内存 LRU 与磁盘缓存
- ImageIO 后台位图准备，Core Animation 可复用图层树
- SVG Path `M/L/H/V/C/S/Q/T/A/Z`、相对指令、重复参数与科学计数法
- 位图、矢量、clipPath、keep-frame 与 matte 渲染
- `UIView.ContentMode` 13 种布局语义，`.redraw` 等同 `.scaleToFill`
- 播放、暂停、恢复、停止、清空、范围、倒放、循环、定位、倍速与跳帧追赶
- 内嵌音频区间调度、定位偏移、音量与静音；倒放不启动音频
- 动态图片、远程图片、富文本、隐藏与逐帧 Drawing Handler
- UIKit Delegate、SwiftUI `ObservableObject` 控制器与 `UIViewRepresentable`
- 指定帧 `UIImage`、PNG Data 与 PNG 序列导出

## Swift Package Manager

```swift
dependencies: [
    .package(
        url: "https://github.com/yichangli/LYSVGAPlayer.git",
        from: "0.1.0"
    ),
]
```

在目标中引用唯一公开 Product：

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "LYSVGAPlayer", package: "LYSVGAPlayer"),
    ]
)
```

仓库当前尚未发布 `0.1.0` tag；远端依赖示例用于说明正式发布后的接入形式。本地开发可通过 Xcode 的 Add Local Package 使用仓库根目录。

## UIKit 使用

```swift
import LYSVGAPlayer
import UIKit

@MainActor
final class AnimationViewController: UIViewController {
    private let playerView = LYSVGAPlayerView()
    private let loader = LYSVGAAssetLoader.shared

    func loadAnimation(from url: URL) async throws {
        playerView.contentMode = .scaleAspectFit
        playerView.repeatMode = .forever
        playerView.isMuted = false
        try await playerView.load(.remote(url), using: loader, autoplay: true)
    }

    func loadBundledAnimation() async throws {
        try await playerView.load(named: "headwear", autoplay: true)
    }
}
```

需要保留鉴权头、请求方法、Body、超时或网络策略时，直接传入 `URLRequest`：

```swift
var request = URLRequest(url: URL(string: "https://example.com/headwear.svga")!)
request.httpMethod = "POST"
request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
request.httpBody = Data(#"{"userID":"42"}"#.utf8)
request.timeoutInterval = 15

try await playerView.load(
    .request(request),
    using: .shared,
    cachePolicy: .automatic,
    autoplay: true
)
```

请求缓存键由标准化 URL、method、排序后的 headers、Body 摘要、超时及相关网络策略共同生成，落盘时只保存 SHA-256；不会把 `Authorization` 等头字段原文写入文件名。无法稳定重放的 `httpBodyStream` 会返回 `LYSVGAError.invalidRequest`。

播放控制：

```swift
try playerView.play(range: 10...80)
try playerView.play(reverse: true)
playerView.pause()
playerView.resume()
playerView.seek(toProgress: 0.5, andPlay: true)
playerView.stop()
playerView.clear()
```

`repeatMode` 支持 `.once`、`.count(UInt)` 与 `.forever`；`.count(0)` 在播放时返回配置错误。`playbackRate` 会钳制到 `0.5...2.0`。`endBehavior` 支持 `.clear`、`.holdStartFrame` 与 `.holdEndFrame`。

### LYSVGAImageView 与 Storyboard

只需要通过资源名或 URL 自动加载时，可以使用 `LYSVGAImageView`：

```swift
let imageView = LYSVGAImageView()
imageView.contentMode = .scaleAspectFit
imageView.autoPlay = true
imageView.loops = 0
imageView.imageName = "headwear"

// HTTP(S) 字符串会自动作为远程资源加载。
imageView.imageName = "https://example.com/headwear.svga"
```

`imageName` 默认在 `resourceBundle`（默认 `.main`）中查找 `.svga` 文件；名称自带扩展名时不会重复追加。新赋值采用 last-request-wins，空名称和 `clear()` 都会取消旧任务并清空画面。`assetLoader` 与 `cachePolicy` 可在赋值 `imageName` 前替换，默认分别为 `.shared` 与 `.automatic`。

在 Storyboard 中把视图 Custom Class 设为 `LYSVGAImageView`，即可配置 `autoPlay`、`imageName`、`loops` 和 `clearsAfterStop`：

- `loops <= 0` 为无限循环，`1` 为播放一次，`> 1` 为指定次数。
- `clearsAfterStop = true` 对应 `.clear`；从 `true` 改为 `false` 对应 `.holdEndFrame`。
- `.holdStartFrame` 仍通过强类型 `endBehavior` 设置。
- `displayLinkRunLoopMode` 默认 `.common`，也可设为 `.default` 或自定义 Mode；播放中修改不会重置帧号、时间线或音频。

## SwiftUI 使用

```swift
import LYSVGAPlayer
import SwiftUI

struct AnimationView: View {
    @StateObject private var controller = LYSVGAPlayerController()
    private let loader = LYSVGAAssetLoader()

    var body: some View {
        LYSVGAView(controller: controller, contentMode: .scaleAspectFit)
            .task {
                guard let url = Bundle.main.url(forResource: "sample", withExtension: "svga") else { return }
                try? await controller.load(.file(url), using: loader, autoplay: true)
            }
    }
}
```

`LYSVGAPlayerController` 始终持有同一个 `LYSVGAPlayerView`，通过 iOS 16 可用的 `ObservableObject/@Published` 发布播放状态、帧、进度、循环和错误事件。

Controller 会转发 `repeatMode`、`endBehavior`、`playbackRate`、`allowsFrameSkipping`、`isMuted`、`audioVolume` 与 `displayLinkRunLoopMode`。SwiftUI 层仍使用同一套 UIKit/Core Animation 播放内核。

## 从 SVGAPlayer-iOS 迁移

LYSVGAPlayer 面向 Swift 6 项目，不提供 Objective-C 兼容层，也不声明旧库同名的 `SVGAPlayer` 或 `SVGAParser`。新项目可以直接依赖本库；旧项目需要按下表做一次明确迁移，不能只替换依赖而保持源码不变。

| SVGAPlayer-iOS 2.5.8 | LYSVGAPlayer | 说明 |
| --- | --- | --- |
| `SVGAPlayer` | `LYSVGAPlayerView` | 强类型 UIKit 播放器 |
| `SVGAImageView.autoPlay/imageName` | `LYSVGAImageView.autoPlay/imageName` | Bundle 名称和 HTTP(S) URL 便捷加载 |
| `parseWithNamed:inBundle:` | `playerView.load(named:in:using:autoplay:)` | `async throws`，资源缺失返回 `.missingResource` |
| `parseWithURLRequest:` | `playerView.load(.request(request), using:autoplay:)` | 保留 method、headers、Body、timeout 与网络策略 |
| `loops` | `repeatMode` 或 `loops` | 推荐 `.once`、`.count`、`.forever` |
| `clearsAfterStop` | `endBehavior` 或 `clearsAfterStop` | 推荐强类型结束行为 |
| `mainRunLoopMode` | `displayLinkRunLoopMode` | 默认 `.common`，运行中可切换 |
| `referenceLayer` 动态替换 | 无对应接口 | 上游已废弃且参数未参与实际渲染；请使用动态图片、文本、隐藏和 Drawing Handler |

迁移后的解析、安装和播放可以合并为一次调用：

```swift
try await playerView.load(
    named: "headwear",
    in: .main,
    using: .shared,
    cachePolicy: .automatic,
    autoplay: true
)
```

## 动态内容

```swift
playerView.setImage(avatarImage, forKey: "avatar.png")
try await playerView.setImage(from: avatarURL, forKey: "avatar")
playerView.setAttributedText(title, forKey: "title")
playerView.setHidden(true, forKey: "decoration.vector")
playerView.setDrawingHandler({ layer, frame in
    layer.opacity = frame.isMultiple(of: 2) ? 1 : 0.8
}, forKey: "custom")
playerView.clearDynamicContents()
```

动态 Key 同时接受原始 Sprite Key 与移除 `.matte`、`.vector`、常见图片扩展名后的标准 Key。相同 Key 的远程图片遵循 last-request-wins，覆盖、清空或释放播放器会取消旧请求。

## 帧导出

```swift
let exporter = try await LYSVGAFrameExporter(video: video)
let image = try exporter.image(atFrame: 12, scale: 2)
let png = try exporter.pngData(atFrame: 12)
let files = try await exporter.exportPNGSequence(frames: 0...20, to: outputDirectory)
```

图像准备与渲染复用播放器 Renderer。渲染限定在主线程，PNG 文件写入使用 Swift 6.2 的并发执行；单边最大 16384 像素且总像素不超过 64 MP。

## 音频与生命周期

- `isMuted` 只把播放器有效音量设为零，动画与音频时间线继续推进。
- `audioVolume` 钳制到 `0...1`，播放倍速同步到音频。
- 倒放不启动内嵌音频。
- 库不修改全局 `AVAudioSession`，宿主应用负责 category、路由、中断和混音策略。
- 进入后台或离开 Window 时暂停；重新激活时只恢复中断前正在播放的实例。
- `LYSVGAImageView.clear()` 与释放会取消其便捷加载任务；播放器清理还会取消动态图片、停止时钟和音频并移除图层。

## Demo、测试与性能

- [Demo](Demo/README.md)：可运行的 UIKit/SwiftUI 双页面示例，包含 V1、V2、matte 与音频公开素材。
- [测试协作](docs/TESTING.md)：自动测试、模拟器、真机与业务素材验收边界。
- [Benchmark](Benchmarks/README.md)：解析、首帧、连续渲染、CPU、内存和帧预算测量及上游对照脚本。
- [架构](docs/ARCHITECTURE.md)：资源管线、并发边界、图层树、播放和清理机制。

测试包含 128 x 128、scale 1、sRGB 的 V1 位图、V2 位图、矢量和 matte 像素容差快照。

## 严格并发说明

LYSVGAPlayer Target 在 Swift 6 语言模式下编译。若从命令行对整个依赖图强制覆盖 `SWIFT_STRICT_CONCURRENCY=complete`，当前 ZIPFoundation 0.9.20 会因其内部可变全局变量在 `Archive+ZIP64.swift` 报错；0.9.19 含有相同实现。该问题属于依赖源码被全局覆盖后的诊断，不是 LYSVGAPlayer Target 的并发错误，仓库不会通过回退依赖版本掩盖它。

## License

LYSVGAPlayer 使用 Apache License 2.0。上游归属说明见 [NOTICE](NOTICE)。
