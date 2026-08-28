# LYSVGAPlayer 测试与协作验收

## 验收分层

| 层级 | 证明内容 | 不能证明 |
| --- | --- | --- |
| Swift 6 构建 | API、类型和本 Target 并发检查可编译 | 动画画面正确或音频可听 |
| 单元测试 | 格式、缓存、路径、时间线、音频调度和失败语义 | 真实设备性能 |
| 像素快照 | 固定帧渲染没有发生可见像素回归 | 所有生产资源兼容 |
| Simulator Demo | UIKit/SwiftUI、交互和公开资源可运行 | 真机音频路由、iOS 16 运行时 |
| 真机/业务素材 | 实际产品资源、生命周期、听感与持续运行 | 与上游的统一性能比较 |
| 同环境 Benchmark | 相对上游 2.5.8 的解析、端到端首个可见画面、CPU、内存和帧预算 | 其他设备或业务负载的绝对表现 |

## 自动测试

选择已安装的 iOS Simulator：

```bash
xcodebuild \
  -scheme LYSVGAPlayer \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath .build/TestDerivedData \
  -skip-testing:LYSVGABenchmarks \
  test
```

常规测试和 Benchmark 是两个独立 test target。日常回归跳过 `LYSVGABenchmarks`，性能测量使用：

```bash
Benchmarks/run.sh \
  'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  Benchmarks/Results/lysvga.json
```

## 公开样例

Demo 内置四个来自 SVGAPlayer-iOS 2.5.8 的 Apache 2.0 样例：

- `rose_2.0.0.svga`：V2 位图与矢量组合；
- `matteBitmap_1.x.svga`：仅含 `movie.spec` 的 V1 ZIP/JSON；
- `rose_1.5.0.svga`：同时含 `movie.binary` 与 `movie.spec`，用于验证优先 Protobuf 的兼容行为；
- `matteBitmap.svga`：matte；
- `audio_biling.svga`：内嵌音频。

打开 `Demo/LYSVGADemo.xcodeproj`，选择 `LYSVGADemo` scheme。SwiftUI 与 UIKit 两页都应完成以下检查：

1. Bundle 菜单依次加载四个样例，画面非空且进度持续变化。
2. 播放、暂停、停止、循环、倒放和进度定位状态正确。
3. 静音后动画继续，取消静音后音频时间线没有重新从零开始。
4. Replace/Restore 能替换并恢复首个 Sprite。
5. 页面底部控件不被 TabBar 遮挡，横竖屏和不同字号下仍可滚动操作。
6. 文件选择器可以加载本地 `.svga`，URL 入口只接受 HTTPS。

宿主 Demo 配置 `.ambient + mixWithOthers` 的 `AVAudioSession`；库本身不修改全局音频会话。

## 业务素材协作

业务 `.svga` 放入仓库根目录下的 `TestAssets/Local/`。该目录已被 Git 忽略，不会随正常提交上传；未经素材所有者许可不要取消忽略或提交文件。

可运行自动业务素材验收。测试默认读取仓库的 `TestAssets/Local/`，递归遍历 `.svga`，验证解析、图片准备和多个采样帧渲染，并输出不包含素材内容的结构化摘要：

```bash
xcodebuild \
  -scheme LYSVGAPlayer \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath .build/LocalAssetDerivedData \
  -only-testing:LYSVGAPlayerTests/LYSVGALocalAssetAcceptanceTests \
  test
```

目录不存在时该测试自动跳过，不影响公开 CI；也可在 Xcode Test Plan 中设置 `LYSVGA_LOCAL_ASSETS` 覆盖默认路径。

建议按用途建立子目录并保留原文件名：

```text
TestAssets/Local/
├── headwear/
├── sound-wave/
├── seat-emoji/
├── audio/
├── dynamic/
└── stress/
```

每个素材至少记录：来源类别、文件大小、画布、fps、帧数、是否含音频、是否使用 matte/动态 Key、期望循环方式，以及旧播放器截图或录屏。

重点验收：

- 头饰：长时间循环、进入后台、离开 Window、复用 Cell 后无残留。
- 音浪：多个实例并存、暂停恢复、静音和 CPU。
- 麦位表情：小尺寸 contentMode、频繁替换、快速释放。
- 音频：起止帧、`startTime`、定位偏移、循环、系统中断和宿主音频会话。
- 动态元素：原始/标准 Key、本地/远程图片、富文本、隐藏和 Drawing Handler。
- 压力资源：大画布、高 fps、长帧数、多矢量、多 matte 和多音频。

发现问题时请同时提供：素材文件、操作步骤、UIKit/SwiftUI 页面、系统版本、设备、期望结果、实际截图/录屏，以及是否能在上游 2.5.8 复现。

Demo 的 Bundle 菜单也会显示应用 Documents 目录中的 `.svga`。真机安装 Demo 后，可使用 `ios-deploy` 上传私有素材而不修改 Xcode 工程或提交文件：

```bash
ios-deploy --id <DEVICE_UDID> --bundle_id com.lysvga.demo \
  --upload TestAssets/Local/sample.svga \
  --to Documents/sample.svga \
  --no-wifi
```

重新启动 Demo 后，在 UIKit 或 SwiftUI 页面的 `Bundle > Local Assets` 中选择素材。

## iOS 16

Package deployment target 为 iOS 16，代码不依赖 iOS 17 Observation。较新 SDK 上的 deployment target 构建只能证明 API 可用性；iOS 16 运行行为必须在安装了 iOS 16 Simulator Runtime 的机器或 iOS 16 设备上单独验收。

## 性能对照

上游对照必须使用相同设备/模拟器、Runtime、Xcode、Release 构建配置、素材、输出尺寸、迭代数和温度条件。硬门槛使用 `first-playable.v2`：从原始 SVGA Data 开始，包含解析、首阶段图片准备、图层构建、布局和首个像素输出；预热 3 次、测量 30 次，以中位数为判定值并同时记录 P95。首画面计时结束后等待第二阶段位图预热收敛，再进入下一轮。`continuous-render.v2` 清空图片缓存、完成两阶段准备后测量稳态逐帧更新；`first-frame.v2` 仅保留为诊断数据。将上游 2.5.8 结果转换为 `Benchmarks/collect_results.rb` 产出的同一 JSON schema 后运行：

Swift Package 的 XCTest Benchmark 用于 Simulator；真机通过 Demo 内置的 app-hosted Runner 执行。Runner 由启动环境变量 `LYSVGA_DEVICE_BENCHMARK=1` 开启，默认读取应用 Documents 中的 `head_wear_vip9.svga`，完成后写出 `lysvga-device-benchmark.json` 并退出。V1 解析项固定使用只含 `movie.spec` 的 `matteBitmap_1.x.svga`，避免把双格式资源误标为 V1。

```bash
ruby Benchmarks/compare_results.rb \
  Benchmarks/Results/lysvga.json \
  Benchmarks/Results/upstream-2.5.8.json
```

阈值为：解析和端到端首个可见画面中位数不超过上游 110%，连续渲染 CPU 不超过 110%，峰值常驻内存不超过 115%，超出帧预算比例增幅不超过 1 个百分点。缺少同设备上游结果时只记录 LYSVGA 本机基线，不给出达标结论。
