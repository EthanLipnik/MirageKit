//
//  MirageHostWallpaperResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Resolves the host's primary display wallpaper into a compressed transfer payload.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MirageKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
enum MirageHostWallpaperResolver {
    struct Payload: Sendable {
        let imageData: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let bytesPerPixelEstimate: Int
    }

    struct WallpaperWindowCandidate: Equatable, Sendable {
        let windowID: CGWindowID
        let ownerName: String
        let title: String
        let frame: CGRect
        let windowLayer: Int

        init(
            windowID: CGWindowID,
            ownerName: String,
            title: String,
            frame: CGRect,
            windowLayer: Int
        ) {
            self.windowID = windowID
            self.ownerName = ownerName
            self.title = title
            self.frame = frame
            self.windowLayer = windowLayer
        }

        init(window: SCWindow) {
            self.init(
                windowID: window.windowID,
                ownerName: window.owningApplication?.applicationName ?? "",
                title: window.title ?? "",
                frame: window.frame,
                windowLayer: window.windowLayer
            )
        }
    }

    nonisolated package static let requestedMaxPixelWidth = 854
    nonisolated package static let requestedMaxPixelHeight = 480
    nonisolated package static let minimumRequestPixelWidth = 427
    nonisolated package static let minimumRequestPixelHeight = 240
    nonisolated package static let encodedFileExtension = "jpg"
    nonisolated package static let encodedContentType = "image/jpeg"
    nonisolated package static let encodedCompressionQuality: CGFloat = 0.5
    nonisolated private static let minEncodedMaxDimension = 360

    static func payload(
        preferredMaxPixelWidth: Int,
        preferredMaxPixelHeight: Int
    ) async -> Payload? {
        guard let primaryDisplayID = resolvedPrimaryPhysicalDisplayID() else {
            return nil
        }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else {
            return nil
        }

        guard let display = content.displays.first(where: { $0.displayID == primaryDisplayID }) else {
            return nil
        }

        let candidates = content.windows.map(WallpaperWindowCandidate.init(window:))
        guard let candidate = wallpaperWindowCandidate(from: candidates, for: display.frame),
              let wallpaperWindow = content.windows.first(where: { $0.windowID == candidate.windowID }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: wallpaperWindow)
        let captureInfo = SCShareableContent.info(for: filter)
        let pointPixelScale = max(CGFloat(captureInfo.pointPixelScale), 1)
        let captureRect = captureInfo.contentRect.integral
        let sourcePixelWidth = max(1, Int(ceil(captureRect.width * pointPixelScale)))
        let sourcePixelHeight = max(1, Int(ceil(captureRect.height * pointPixelScale)))
        let targetSize = resolvedMaxOutputSize(
            sourcePixelWidth: sourcePixelWidth,
            sourcePixelHeight: sourcePixelHeight,
            preferredMaxPixelWidth: preferredMaxPixelWidth,
            preferredMaxPixelHeight: preferredMaxPixelHeight
        )
        let captureEncodeInterval = MirageLogger.beginInterval(.host, "HostWallpaper.CaptureEncode")
        let image = await captureImage(
            with: filter,
            targetPixelWidth: Int(targetSize.width.rounded(.down)),
            targetPixelHeight: Int(targetSize.height.rounded(.down))
        )
        MirageLogger.endInterval(captureEncodeInterval)

        guard let image else {
            return nil
        }

        return payload(
            from: image,
            preferredMaxPixelWidth: preferredMaxPixelWidth,
            preferredMaxPixelHeight: preferredMaxPixelHeight
        )
    }

    nonisolated static func resolvedPrimaryPhysicalDisplayID(
        mainDisplayID: CGDirectDisplayID = CGMainDisplayID(),
        onlineDisplayIDs: [CGDirectDisplayID] = onlineDisplayIDs(),
        isVirtualDisplay: (CGDirectDisplayID) -> Bool = { CGVirtualDisplayBridge.isVirtualDisplay($0) }
    ) -> CGDirectDisplayID? {
        if !isVirtualDisplay(mainDisplayID) {
            return mainDisplayID
        }

        return onlineDisplayIDs.first(where: { !isVirtualDisplay($0) })
    }

    nonisolated static func wallpaperWindowCandidate(
        from windows: [WallpaperWindowCandidate],
        for displayFrame: CGRect
    ) -> WallpaperWindowCandidate? {
        windows
            .compactMap { candidate -> (WallpaperWindowCandidate, CGFloat)? in
                guard candidate.ownerName == "Dock",
                      candidate.title.hasPrefix("Wallpaper"),
                      candidate.windowLayer < 0 else {
                    return nil
                }

                let intersection = candidate.frame.intersection(displayFrame)
                guard !intersection.isNull,
                      intersection.width > 0,
                      intersection.height > 0 else {
                    return nil
                }

                return (candidate, intersection.width * intersection.height)
            }
            .max { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.windowID > rhs.0.windowID
                }
                return lhs.1 < rhs.1
            }?
            .0
    }

    private static func payload(
        from image: CGImage,
        preferredMaxPixelWidth: Int,
        preferredMaxPixelHeight: Int
    ) -> Payload? {
        let targetSize = resolvedMaxOutputSize(
            sourcePixelWidth: image.width,
            sourcePixelHeight: image.height,
            preferredMaxPixelWidth: preferredMaxPixelWidth,
            preferredMaxPixelHeight: preferredMaxPixelHeight
        )

        var currentSize = targetSize
        while Int(currentSize.width.rounded(.down)) >= minEncodedMaxDimension,
              Int(currentSize.height.rounded(.down)) >= minEncodedMaxDimension {
            guard let cgImage = scaledImage(
                from: image,
                targetPixelWidth: currentSize.width,
                targetPixelHeight: currentSize.height
            ) else {
                return nil
            }

            if let encoded = encodedData(for: cgImage) {
                return Payload(
                    imageData: encoded,
                    pixelWidth: cgImage.width,
                    pixelHeight: cgImage.height,
                    bytesPerPixelEstimate: 4
                )
            }

            currentSize = CGSize(
                width: floor(currentSize.width * 0.85),
                height: floor(currentSize.height * 0.85)
            )
        }

        return nil
    }

    nonisolated private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        return Array(displayIDs.prefix(Int(displayCount)))
    }

    nonisolated package static func resolvedMaxOutputSize(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        preferredMaxPixelWidth: Int,
        preferredMaxPixelHeight: Int
    ) -> CGSize {
        let boundedWidth = min(
            max(1, preferredMaxPixelWidth),
            requestedMaxPixelWidth,
            sourcePixelWidth
        )
        let boundedHeight = min(
            max(1, preferredMaxPixelHeight),
            requestedMaxPixelHeight,
            sourcePixelHeight
        )

        let sourceWidth = CGFloat(sourcePixelWidth)
        let sourceHeight = CGFloat(sourcePixelHeight)
        let widthScale = CGFloat(boundedWidth) / sourceWidth
        let heightScale = CGFloat(boundedHeight) / sourceHeight
        let scale = min(widthScale, heightScale, 1)

        // The requested resolution is an upper bound, never a forced canvas.
        // Keep the source aspect ratio and original size whenever it already fits.
        return CGSize(
            width: max(1, floor(sourceWidth * scale)),
            height: max(1, floor(sourceHeight * scale))
        )
    }

    nonisolated package static func clampedRequestedOutputSize(
        preferredMaxPixelWidth: Int,
        preferredMaxPixelHeight: Int
    ) -> CGSize {
        CGSize(
            width: min(
                max(preferredMaxPixelWidth, minimumRequestPixelWidth),
                requestedMaxPixelWidth
            ),
            height: min(
                max(preferredMaxPixelHeight, minimumRequestPixelHeight),
                requestedMaxPixelHeight
            )
        )
    }

    private static func captureImage(
        with filter: SCContentFilter,
        targetPixelWidth: Int,
        targetPixelHeight: Int
    ) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, targetPixelWidth)
        configuration.height = max(1, targetPixelHeight)
        configuration.showsCursor = false

        return try? await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let image else {
                    continuation.resume(
                        throwing: MirageError.protocolError("Wallpaper screenshot capture returned no image")
                    )
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    private static func scaledImage(
        from image: CGImage,
        targetPixelWidth: CGFloat,
        targetPixelHeight: CGFloat
    ) -> CGImage? {
        let width = max(1, Int(targetPixelWidth.rounded(.down)))
        let height = max(1, Int(targetPixelHeight.rounded(.down)))
        if image.width == width, image.height == height {
            return image
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodedData(for image: CGImage) -> Data? {
        let encodedImage = opaqueEncodedImage(from: image) ?? image

        if let jpegData = encodeJPEG(encodedImage, quality: encodedCompressionQuality),
           fitsInlineControlPayload(
               imageData: jpegData,
               pixelWidth: encodedImage.width,
               pixelHeight: encodedImage.height,
               bytesPerPixelEstimate: 4
           ) {
            return jpegData
        }

        return nil
    }

    private static func encodeJPEG(
        _ image: CGImage,
        quality: CGFloat
    ) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    private static func opaqueEncodedImage(from image: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func fitsInlineControlPayload(
        imageData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        bytesPerPixelEstimate: Int
    ) -> Bool {
        let message = HostWallpaperMessage(
            requestID: UUID(),
            imageData: imageData,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            bytesPerPixelEstimate: bytesPerPixelEstimate
        )
        guard let encoded = try? JSONEncoder().encode(message) else {
            return false
        }
        return encoded.count <= LoomMessageLimits.maxInlineAssetPayloadBytes
    }
}
#endif
