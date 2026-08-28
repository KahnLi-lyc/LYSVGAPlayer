# LYSVGADemo

`LYSVGADemo.xcodeproj` contains an iOS 16 demo with SwiftUI and UIKit tabs. Both tabs support bundled samples, local files, HTTPS URLs, playback controls, mute, loop, reverse playback, seeking, and dynamic image replacement.

Open `LYSVGADemo.xcodeproj`, select the `LYSVGADemo` scheme, and run on an iOS 16 or newer simulator/device. The project consumes the parent repository through a local Swift Package reference.

The bundled `.svga` files come from `Rogue24/SVGAPlayer-iOS` 2.5.8 and remain under Apache License 2.0. The repository root `LICENSE` and `NOTICE` contain the applicable license and attribution.

`generate_project.rb` regenerates the checked-in Xcode project when the Ruby `xcodeproj` gem is installed.
