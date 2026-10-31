import SwiftUI
import UIKit

@MainActor
public struct LYSVGAView: UIViewRepresentable {
    // Not observed: the UIKit player renders itself, so frame updates published by the
    // controller must not re-evaluate this representable on every display tick.
    private let controller: LYSVGAPlayerController
    private let contentMode: UIView.ContentMode
    private let clipsToBounds: Bool

    public init(
        controller: LYSVGAPlayerController,
        contentMode: UIView.ContentMode = .scaleAspectFit,
        clipsToBounds: Bool = false
    ) {
        self.controller = controller
        self.contentMode = contentMode
        self.clipsToBounds = clipsToBounds
    }

    public func makeUIView(context: Context) -> LYSVGAPlayerView {
        let playerView = controller.playerView
        configure(playerView)
        return playerView
    }

    public func updateUIView(_ playerView: LYSVGAPlayerView, context: Context) {
        configure(playerView)
    }

    private func configure(_ playerView: LYSVGAPlayerView) {
        playerView.contentMode = contentMode
        playerView.clipsToBounds = clipsToBounds
    }
}
