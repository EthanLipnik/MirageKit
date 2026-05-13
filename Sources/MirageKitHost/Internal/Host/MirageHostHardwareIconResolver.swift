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

    private static let cachedIconAssets: [CoreTypesIconAsset] = loadMetadataCoreTypesIconAssets()

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

    private static func resolvedAsset(
        preferredIconName: String?,
        hardwareMachineFamily: String?,
        hardwareModelIdentifier: String?
    ) -> CoreTypesIconAsset? {
        let iconAssets = cachedIconAssets
        guard !iconAssets.isEmpty else {
            return nil
        }

        let normalizedPreferredName = mirageNormalizedHardwareMetadataValue(preferredIconName)
        let normalizedFamily = mirageNormalizedHardwareMetadataValue(hardwareMachineFamily)
        let normalizedModel = mirageNormalizedHardwareMetadataValue(hardwareModelIdentifier)

        var selectedAsset: CoreTypesIconAsset?

        if let normalizedPreferredName,
           preferredIconNameMatchesMetadata(
               normalizedPreferredName,
               normalizedFamily: normalizedFamily,
               normalizedModel: normalizedModel
           ) {
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
                .filter { mirageMacHardwareIconName($0.lowercasedFilename, matchesMachineFamily: normalizedFamily) }
                .max(by: { lhs, rhs in lhs.fileSize < rhs.fileSize })
        }

        if selectedAsset == nil, let normalizedModel {
            selectedAsset = iconAssets
                .filter { $0.lowercasedFilename.contains(normalizedModel) }
                .max(by: { lhs, rhs in lhs.fileSize < rhs.fileSize })
        }

        return selectedAsset
    }

    private static func preferredIconNameMatchesMetadata(
        _ iconName: String,
        normalizedFamily: String?,
        normalizedModel: String?
    ) -> Bool {
        if let normalizedFamily {
            return mirageMacHardwareIconName(iconName, matchesMachineFamily: normalizedFamily)
        }

        guard let normalizedModel,
              let knownFamily = knownMachineFamily(forModelIdentifier: normalizedModel) else {
            return true
        }
        return mirageMacHardwareIconName(iconName, matchesMachineFamily: knownFamily)
    }

    private static func knownMachineFamily(forModelIdentifier modelIdentifier: String) -> String? {
        switch modelIdentifier {
        case "mac13,1",
             "mac13,2",
             "mac14,13",
             "mac14,14",
             "mac15,14",
             "mac16,9":
            return "macstudio"
        case "mac14,3",
             "mac14,12",
             "mac16,10",
             "mac16,11":
            return "macmini"
        default:
            return nil
        }
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

    /// Encodes a thumbnail image for host hardware-icon transfer.
    private static func pngData(for image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return mutableData as Data
    }
}
#endif
