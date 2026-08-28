import SwiftUI
import UIKit

@MainActor
public struct LYSVGAView: UIViewRepresentable {
    @ObservedObject private var controller: LYSVGAPlayerController
    private let contentMode: UIView.ContentMode
    private let clipsToBounds: Bool

    public init(
        controller: LYSVGAPlayerController,
        contentMode: UIView.ContentMode = .scaleAspectFit,
        clipsToBounds: Bool = false
    ) {
        _controller = ObservedObject(wrappedValue: controller)
        self.contentMode = contentMode
        self.clipsToBounds = clipsToBounds
    }

    public func makeUIView(context: Context) -> LYSVGAPlayerView {
        configure(controller.playerView)
    }

    public func updateUIView(_ playerView: LYSVGAPlayerView, context: Context) {
        configure(playerView)
    }

    private func configure(_ playerView: LYSVGAPlayerView) -> LYSVGAPlayerView {
        playerView.contentMode = contentMode
        playerView.clipsToBounds = clipsToBounds
        return playerView
    }
}
