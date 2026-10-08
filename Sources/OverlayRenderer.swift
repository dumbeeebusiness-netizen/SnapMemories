import UIKit

/// Legt das Snapchat-Overlay (Text, Sticker, Zeichnungen) über das Foto – so wie es in Snapchat aussah.
enum OverlayRenderer {
    static func merge(main: URL, overlay: URL, to dest: URL) throws {
        guard let base = UIImage(contentsOfFile: main.path),
              let top = UIImage(contentsOfFile: overlay.path) else { throw ImportError.overlayFailed }

        let size = base.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
            top.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.92) else { throw ImportError.overlayFailed }
        try data.write(to: dest)
    }
}
