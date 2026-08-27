import UIKit

enum LYSVGACanvasLayout {
    static func frame(videoSize: CGSize, in bounds: CGRect, contentMode: UIView.ContentMode) -> CGRect {
        guard isValid(videoSize), isValid(bounds.size) else {
            return .zero
        }

        switch contentMode {
        case .scaleToFill, .redraw:
            return bounds
        case .scaleAspectFit:
            return scaledFrame(videoSize: videoSize, in: bounds, scale: min(
                bounds.width / videoSize.width,
                bounds.height / videoSize.height
            ))
        case .scaleAspectFill:
            return scaledFrame(videoSize: videoSize, in: bounds, scale: max(
                bounds.width / videoSize.width,
                bounds.height / videoSize.height
            ))
        case .center:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .center, vertical: .center)
        case .top:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .center, vertical: .minimum)
        case .bottom:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .center, vertical: .maximum)
        case .left:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .minimum, vertical: .center)
        case .right:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .maximum, vertical: .center)
        case .topLeft:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .minimum, vertical: .minimum)
        case .topRight:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .maximum, vertical: .minimum)
        case .bottomLeft:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .minimum, vertical: .maximum)
        case .bottomRight:
            return alignedFrame(videoSize: videoSize, in: bounds, horizontal: .maximum, vertical: .maximum)
        @unknown default:
            return bounds
        }
    }

    private enum Alignment {
        case minimum
        case center
        case maximum
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func scaledFrame(videoSize: CGSize, in bounds: CGRect, scale: CGFloat) -> CGRect {
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func alignedFrame(
        videoSize: CGSize,
        in bounds: CGRect,
        horizontal: Alignment,
        vertical: Alignment
    ) -> CGRect {
        CGRect(
            x: alignedOrigin(
                minimum: bounds.minX,
                containerLength: bounds.width,
                contentLength: videoSize.width,
                alignment: horizontal
            ),
            y: alignedOrigin(
                minimum: bounds.minY,
                containerLength: bounds.height,
                contentLength: videoSize.height,
                alignment: vertical
            ),
            width: videoSize.width,
            height: videoSize.height
        )
    }

    private static func alignedOrigin(
        minimum: CGFloat,
        containerLength: CGFloat,
        contentLength: CGFloat,
        alignment: Alignment
    ) -> CGFloat {
        switch alignment {
        case .minimum:
            minimum
        case .center:
            minimum + (containerLength - contentLength) / 2
        case .maximum:
            minimum + containerLength - contentLength
        }
    }
}
