import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Grabs a still of the main display via ScreenCaptureKit and hands back a
/// downsized JPEG, ready to base64-encode for the Claude vision API.
///
/// Requires the Screen Recording permission; the first capture triggers the
/// system prompt. Callers should surface `.permissionDenied` to the user.
enum ScreenCapture {
    enum CaptureError: Error {
        case noDisplay
        case permissionDenied
        case encodingFailed
    }

    struct Shot {
        let jpegBase64: String
        let pixelWidth: Int
        let pixelHeight: Int
        /// A tiny grayscale fingerprint for cheap "did the screen change?"
        /// comparisons — lets the observer skip API calls on static screens.
        let signature: [UInt8]
    }

    /// Longest edge of the downsampled capture. A touch higher than strictly
    /// needed for reading, to sharpen small on-screen targets (checkboxes, tiny
    /// buttons) so grounding a click is more accurate — still cheap since the
    /// agent loop only ever keeps one screenshot in context at a time.
    static let maxEdge = 1600

    static func captureMainDisplay() async throws -> Shot {
        // ScreenCaptureKit hands back an all-black frame (rather than throwing)
        // when Screen Recording permission isn't actually live for this build —
        // a common trap when re-signed builds invalidate a prior grant. The
        // first frame after launch can also occasionally be black, so retry
        // once before concluding it's a permission problem.
        var lastScaled: CGImage?
        for attempt in 0..<2 {
            let cgImage = try await captureCGImage()
            let scaled = downscale(cgImage, maxEdge: maxEdge)
            lastScaled = scaled
            let sig = signature(of: scaled)

            if isEffectivelyBlack(sig) {
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    continue
                }
                throw CaptureError.permissionDenied
            }

            guard let data = jpegData(from: scaled, quality: 0.7) else {
                throw CaptureError.encodingFailed
            }
            return Shot(
                jpegBase64: data.base64EncodedString(),
                pixelWidth: scaled.width,
                pixelHeight: scaled.height,
                signature: sig
            )
        }
        // Both attempts came back black.
        _ = lastScaled
        throw CaptureError.permissionDenied
    }

    private static func captureCGImage() async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // ScreenCaptureKit surfaces a denied permission as a thrown error.
            throw CaptureError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = true

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    /// True when a signature is essentially all-black — the tell-tale sign of a
    /// missing/stale Screen Recording grant. A real screen almost always has a
    /// menu bar and other non-black pixels, so this rarely false-positives.
    private static func isEffectivelyBlack(_ signature: [UInt8]) -> Bool {
        guard let peak = signature.max() else { return true }
        return peak < 8
    }

    // MARK: - Change detection

    /// A `side`×`side` grayscale thumbnail, flattened to bytes.
    static func signature(of image: CGImage, side: Int = 12) -> [UInt8] {
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = ctx.data else { return [] }

        let rowBytes = ctx.bytesPerRow
        let ptr = raw.bindMemory(to: UInt8.self, capacity: rowBytes * side)
        var out = [UInt8]()
        out.reserveCapacity(side * side)
        for y in 0..<side {
            for x in 0..<side {
                out.append(ptr[y * rowBytes + x])
            }
        }
        return out
    }

    /// Mean absolute per-pixel difference between two signatures (0…255).
    /// Returns a large value if the signatures are missing or mismatched.
    static func meanAbsDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var sum = 0
        for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    // MARK: - Image helpers

    private static func downscale(_ image: CGImage, maxEdge: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxEdge else { return image }

        let scale = CGFloat(maxEdge) / CGFloat(longest)
        let w = Int(CGFloat(image.width) * scale)
        let h = Int(CGFloat(image.height) * scale)

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
