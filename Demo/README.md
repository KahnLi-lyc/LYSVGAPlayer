# LYSVGADemo

`LYSVGADemo.xcodeproj` contains an iOS 16 demo with SwiftUI, UIKit, and multi-instance list tabs. The player tabs support bundled samples, local files, HTTPS URLs, playback controls, mute, loop, reverse playback, seeking, and dynamic image replacement.

The `List` tab renders 200 friend-style rows with visible-cell-only SVGA playback. It prefers up to 12 `.svga` files from the app Documents directory and falls back to bundled samples. `Single` reuses one asset across the list, while `Mixed` cycles through the loaded asset pool. The toolbar can run a repeatable three-second warmup plus 30-second automatic scroll benchmark; the result is written to `headwear-list-benchmark.json` in Documents.

Open `LYSVGADemo.xcodeproj`, select the `LYSVGADemo` scheme, and run on an iOS 16 or newer simulator/device. The project consumes the parent repository through a local Swift Package reference.

The bundled `.svga` files come from `Rogue24/SVGAPlayer-iOS` 2.5.8 and remain under Apache License 2.0. The repository root `LICENSE` and `NOTICE` contain the applicable license and attribution.

`generate_project.rb` regenerates the checked-in Xcode project when the Ruby `xcodeproj` gem is installed.
