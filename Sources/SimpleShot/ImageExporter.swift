import AppKit

@MainActor
enum ImageExporter {
    /// pointSize 用于写入正确的 DPI（Retina 下为 144），粘贴时尺寸与屏幕一致
    private static func bitmap(_ image: CGImage, pointSize: CGSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(cgImage: image)
        if pointSize.width > 0, pointSize.height > 0 {
            rep.size = pointSize
        }
        return rep
    }

    static func copyToPasteboard(_ image: CGImage, pointSize: CGSize) {
        let rep = bitmap(image, pointSize: pointSize)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }
}
