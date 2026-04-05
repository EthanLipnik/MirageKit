//
//  MirageHostHardwareIconResolver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if os(macOS)
import CoreGraphics
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
        let cgImage = thumbnailCGImage(
            at: resolvedAsset.path,
            maxPixelSize: maxPixelSize
        ),
        let pngData = pngData(for: cgImage) else {
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
        let cgImage = thumbnailCGImage(
            at: resolvedAsset.path,
            maxPixelSize: maxPixelSize
        ) else {
            return nil
        }

        return heifOrPNGData(
            for: cgImage,
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

    private static func thumbnailCGImage(at path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let clampedPixelSize = min(max(maxPixelSize, 128), 1024)
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func pngData(for image: CGImage) -> Data? {
        encodeImage(
            image,
            type: UTType.png,
            properties: nil
        )
    }

    private static func heifOrPNGData(
        for image: CGImage,
        compressionQuality: Double
    ) -> Data? {
        if let heifData = encodeImage(
            image,
            type: .heic,
            properties: [
                kCGImageDestinationLossyCompressionQuality: max(0.1, min(1.0, compressionQuality)),
            ] as CFDictionary
        ),
        !heifData.isEmpty {
            return heifData
        }

        return pngData(for: image)
    }

    private static func encodeImage(
        _ image: CGImage,
        type: UTType,
        properties: CFDictionary?
    ) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
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
