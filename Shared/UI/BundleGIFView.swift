//
//  BundleGIFView.swift
//  Finance Wizard
//
//  Plays a GIF shipped in the app bundle (asset catalogs flatten GIFs to one frame).
//

import ImageIO
import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIImageView` so a bundled GIF can animate.
struct BundleGIFView: UIViewRepresentable {
    var resource: String
    var ext: String = "gif"

    func makeUIView(context: Context) -> IntrinsicZeroImageView {
        let imageView = IntrinsicZeroImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let url = Bundle.main.url(forResource: resource, withExtension: ext)
            ?? Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: "Resources")
        if let url, let data = try? Data(contentsOf: url) {
            imageView.image = UIImage.fw_animatedGIF(data: data)
        }
        return imageView
    }

    func updateUIView(_ uiView: IntrinsicZeroImageView, context: Context) {}
}

/// Lets SwiftUI’s `.frame` own the size (plain UIImageView fights the layout).
final class IntrinsicZeroImageView: UIImageView {
    override var intrinsicContentSize: CGSize { .zero }
}

private extension UIImage {
    static func fw_animatedGIF(data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var frames: [UIImage] = []
        var duration: Double = 0
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            duration += fw_gifFrameDuration(source: source, index: index)
        }
        guard !frames.isEmpty else { return nil }
        if duration <= 0 { duration = Double(frames.count) * 0.1 }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    static func fw_gifFrameDuration(source: CGImageSource, index: Int) -> Double {
        let fallback = 0.1
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return fallback }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
        guard let delay, delay > 0.011 else { return fallback }
        return delay
    }
}
