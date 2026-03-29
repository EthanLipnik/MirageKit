//
//  MirageHostHardwareIconResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if os(macOS)
import AppKit
import Foundation
import ImageIO
import MirageKit
import UniformTypeIdentifiers

enum MirageHostHardwareIconResolver {
    struct Payload {
        let pngData: Data
        let iconName: String
    }

    private struct CoreTypesIconAsset {
        let path: String
        let lowercasedFilename: String
        let originalFilename: String
        let fileSize: Int
    }

    private static let cachedBundlePath: String? = resolveMetadataCoreTypesBundlePath()
    private static let cachedIconAssets: [CoreTypesIconAsset] = loadMetadataCoreTypesIconAssets()

    static func prewarmCache() {
        _ = cachedBundlePath
        _ = cachedIconAssets
    }

    static func payload(
        preferredIconName: String?,
        hardwareMachineFamily: String?,
        hardwareModelIdentifier: String?,
        maxPixelSize: Int
    ) -> Payload? {
        guard let resolvedAsset = resolvedAsset(
            preferredIconName: preferredIconName,
            hardwareMachineFamily: hardwareMachineFamily,
            hardwareModelIdentifier: hardwareModelIdentifier
        ),
        let image = NSImage(contentsOfFile: resolvedAsset.path),
        let pngData = pngData(for: image, maxPixelSize: maxPixelSize) else {
            return nil
        }

        return Payload(
            pngData: pngData,
            iconName: resolvedAsset.originalFilename
        )
    }

    static func cloudKitShareThumbnailData(
        preferredIconName: String?,
        hardwareMachineFamily: String?,
        hardwareModelIdentifier: String?,
        maxPixelSize: Int = 512,
        compressionQuality: Double = 0.35
    ) -> Data? {
        guard let resolvedAsset = resolvedAsset(
            preferredIconName: preferredIconName,
            hardwareMachineFamily: hardwareMachineFamily,
            hardwareModelIdentifier: hardwareModelIdentifier
        ),
        let image = NSImage(contentsOfFile: resolvedAsset.path) else {
            return nil
        }

        return heifOrPNGData(
            for: image,
            maxPixelSize: maxPixelSize,
            compressionQuality: compressionQuality
        )
    }

    private static func resolvedAsset(
        preferredIconName: String?,
        hardwareMachineFamily: String?,
        hardwareModelIdentifier: String?
    ) -> CoreTypesIconAsset? {
        let iconAssets = metadataCoreTypesIconAssets()
        guard !iconAssets.isEmpty else {
            return nil
        }

        let normalizedPreferredName = preferredIconName?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFamily = hardwareMachineFamily?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = hardwareModelIdentifier?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var selectedAsset: CoreTypesIconAsset?

        if let normalizedPreferredName {
            selectedAsset = iconAssets
                .filter { $0.lowercasedFilename == normalizedPreferredName }
                .max(by: { lhs, rhs in lhs.fileSize < rhs.fileSize })

            if selectedAsset == nil {
                let preferredStem = normalizedPreferredName.replacingOccurrences(of: ".icns", with: "")
                selectedAsset = iconAssets
                    .filter { asset in
                        let assetStem = asset.lowercasedFilename.replacingOccurrences(of: ".icns", with: "")
                        return assetStem.hasPrefix(preferredStem) || preferredStem.hasPrefix(assetStem)
                    }
                    .max(by: { lhs, rhs in lhs.fileSize < rhs.fileSize })
            }
        }

        if selectedAsset == nil, let normalizedFamily {
            selectedAsset = iconAssets
                .filter { matchesMachineFamily(normalizedFamily, iconName: $0.lowercasedFilename) }
                .max(by: { lhs, rhs in lhs.fileSize < rhs.fileSize })
        }

        if selectedAsset == nil, let normalizedModel {
            selectedAsset = iconAssets
                .filter { $0.lowercasedFilename.contains(normalizedModel) }
                .max(by: { lhs, rhs in lhs.fileSize < rhs.fileSize })
        }

        return selectedAsset
    }

    private static func metadataCoreTypesIconAssets() -> [CoreTypesIconAsset] {
        cachedIconAssets
    }

    private static func metadataCoreTypesBundlePath() -> String? {
        cachedBundlePath
    }

    private static func loadMetadataCoreTypesIconAssets() -> [CoreTypesIconAsset] {
        guard let bundlePath = resolveMetadataCoreTypesBundlePath() else {
            return []
        }

        var assets: [CoreTypesIconAsset] = []
        let fileManager = FileManager.default

        if let enumerator = fileManager.enumerator(atPath: bundlePath) {
            for case let relativePath as String in enumerator {
                guard relativePath.lowercased().hasSuffix(".icns") else {
                    continue
                }

                let fullPath = bundlePath + "/" + relativePath
                let attributes = try? fileManager.attributesOfItem(atPath: fullPath)
                let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                let originalFilename = (relativePath as NSString).lastPathComponent
                assets.append(
                    CoreTypesIconAsset(
                        path: fullPath,
                        lowercasedFilename: originalFilename.lowercased(),
                        originalFilename: originalFilename,
                        fileSize: fileSize
                    )
                )
            }
        }

        return assets
    }

    private static func resolveMetadataCoreTypesBundlePath() -> String? {
        if let bundlePath = Bundle(identifier: "com.apple.CoreTypes")?.bundlePath,
           FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }

        let likelyParents = [
            "/System/Library/CoreServices",
            "/System/Library/Templates/Data/System/Library/CoreServices",
        ]

        for parent in likelyParents {
            let candidate = parent + "/CoreTypes.bundle"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func pngData(for image: NSImage, maxPixelSize: Int) -> Data? {
        guard let bitmap = rasterizedBitmapImageRep(for: image, maxPixelSize: maxPixelSize) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func heifOrPNGData(
        for image: NSImage,
        maxPixelSize: Int,
        compressionQuality: Double
    ) -> Data? {
        guard let bitmap = rasterizedBitmapImageRep(for: image, maxPixelSize: maxPixelSize) else {
            return nil
        }

        if let cgImage = bitmap.cgImage {
            let mutableData = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) {
                let options: CFDictionary = [
                    kCGImageDestinationLossyCompressionQuality: max(0.1, min(1.0, compressionQuality)),
                ] as CFDictionary
                CGImageDestinationAddImage(destination, cgImage, options)
                if CGImageDestinationFinalize(destination) {
                    let heifData = mutableData as Data
                    if !heifData.isEmpty {
                        return heifData
                    }
                }
            }
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func rasterizedBitmapImageRep(
        for image: NSImage,
        maxPixelSize: Int
    ) -> NSBitmapImageRep? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let targetDimension = CGFloat(min(max(maxPixelSize, 128), 1024))
        let scale = min(targetDimension / sourceSize.width, targetDimension / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawOrigin = CGPoint(
            x: (targetDimension - drawSize.width) * 0.5,
            y: (targetDimension - drawSize.height) * 0.5
        )
        let drawRect = CGRect(origin: drawOrigin, size: drawSize)

        let rendered = NSImage(size: NSSize(width: targetDimension, height: targetDimension))
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: drawRect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        rendered.unlockFocus()

        guard
            let tiffData = rendered.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap
    }

    private static func isMacHardwareIconFilename(_ lowercasedFilename: String) -> Bool {
        lowercasedFilename.contains("macbook") ||
            lowercasedFilename.contains("imac") ||
            lowercasedFilename.contains("macmini") ||
            lowercasedFilename.contains("macstudio") ||
            lowercasedFilename.contains("macpro") ||
            lowercasedFilename.contains("sidebarlaptop") ||
            lowercasedFilename.contains("sidebarmac")
    }

    private static func matchesMachineFamily(_ family: String, iconName: String) -> Bool {
        switch family {
        case "macbook":
            return iconName.contains("macbook") || iconName.contains("sidebarlaptop")
        case "imac":
            return iconName.contains("imac") || iconName.contains("sidebarimac")
        case "macmini":
            return iconName.contains("macmini") || iconName.contains("sidebarmacmini")
        case "macstudio":
            return iconName.contains("macstudio")
        case "macpro":
            return iconName.contains("macpro") || iconName.contains("sidebarmacpro")
        default:
            return isMacHardwareIconFilename(iconName)
        }
    }
}
#endif
