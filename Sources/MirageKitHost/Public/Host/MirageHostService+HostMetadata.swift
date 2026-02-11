//
//  MirageHostService+HostMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Host metadata request handling.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit
import Network

@MainActor
extension MirageHostService {
    func handleHostHardwareIconRequest(
        _ message: ControlMessage,
        from _: MirageConnectedClient,
        connection: NWConnection
    ) async {
        guard let clientContext = clientsByConnection[ObjectIdentifier(connection)] else {
            return
        }

        do {
            let request = try message.decode(HostHardwareIconRequestMessage.self)
            let maxPixelSize = min(max(request.preferredMaxPixelSize, 128), 1024)
            guard let payload = Self.hostHardwareIconPayload(
                preferredIconName: advertisedCapabilities.hardwareIconName,
                hardwareMachineFamily: advertisedCapabilities.hardwareMachineFamily,
                hardwareModelIdentifier: advertisedCapabilities.hardwareModelIdentifier,
                maxPixelSize: maxPixelSize
            ) else {
                MirageLogger.host("Host hardware icon request failed: no icon payload")
                return
            }

            let response = HostHardwareIconMessage(
                pngData: payload.pngData,
                iconName: payload.iconName,
                hardwareModelIdentifier: advertisedCapabilities.hardwareModelIdentifier,
                hardwareMachineFamily: advertisedCapabilities.hardwareMachineFamily
            )
            try await clientContext.send(.hostHardwareIcon, content: response)
            MirageLogger.host("Sent host hardware icon payload bytes=\(payload.pngData.count) icon=\(payload.iconName)")
        } catch {
            MirageLogger.error(.host, "Failed to handle host hardware icon request: \(error)")
        }
    }
}

private extension MirageHostService {
    struct ResolvedHostHardwareIconPayload {
        let pngData: Data
        let iconName: String
    }

    struct CoreTypesIconAsset {
        let path: String
        let lowercasedFilename: String
        let originalFilename: String
        let fileSize: Int
    }

    static func hostHardwareIconPayload(
        preferredIconName: String?,
        hardwareMachineFamily: String?,
        hardwareModelIdentifier: String?,
        maxPixelSize: Int
    ) -> ResolvedHostHardwareIconPayload? {
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
                let preferredStem = normalizedPreferredName.replacing(".icns", with: "")
                selectedAsset = iconAssets
                    .filter { asset in
                        let assetStem = asset.lowercasedFilename.replacing(".icns", with: "")
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

        guard let selectedAsset,
              let image = NSImage(contentsOfFile: selectedAsset.path),
              let pngData = pngData(for: image, maxPixelSize: maxPixelSize)
        else {
            return nil
        }

        return ResolvedHostHardwareIconPayload(
            pngData: pngData,
            iconName: selectedAsset.originalFilename
        )
    }

    static func metadataCoreTypesIconAssets() -> [CoreTypesIconAsset] {
        guard let bundlePath = metadataCoreTypesBundlePath() else {
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

    static func metadataCoreTypesBundlePath() -> String? {
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

    static func pngData(for image: NSImage, maxPixelSize: Int) -> Data? {
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
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
        rendered.unlockFocus()

        guard
            let tiff = rendered.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return pngData
    }

    static func isMacHardwareIconFilename(_ lowercasedFilename: String) -> Bool {
        lowercasedFilename.contains("macbook") ||
            lowercasedFilename.contains("imac") ||
            lowercasedFilename.contains("macmini") ||
            lowercasedFilename.contains("macstudio") ||
            lowercasedFilename.contains("macpro") ||
            lowercasedFilename.contains("sidebarlaptop") ||
            lowercasedFilename.contains("sidebarmac")
    }

    static func matchesMachineFamily(_ family: String, iconName: String) -> Bool {
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
