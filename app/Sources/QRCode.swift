import Foundation
import CoreImage
import CoreGraphics
import ImageIO

enum QRCode {
    static let quietModules = 4

    static func cgImage(_ text: String, module: Int = 8) -> CGImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let raw = f.outputImage else { return nil }
        let m = CGFloat(module)
        let side = raw.extent.width * m + CGFloat(2 * quietModules * module)
        let scaled = raw.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: m, y: m))
            .transformed(by: CGAffineTransform(translationX: CGFloat(quietModules * module), y: CGFloat(quietModules * module)))
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(scaled.composited(over: white), from: rect)
    }

    static func decode(_ image: CGImage) -> String? {
        let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let feats = det?.features(in: CIImage(cgImage: image)) ?? []
        return (feats.first as? CIQRCodeFeature)?.messageString
    }

    static func pngData(_ image: CGImage) -> Data? {
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    static func image(fromPNG data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
