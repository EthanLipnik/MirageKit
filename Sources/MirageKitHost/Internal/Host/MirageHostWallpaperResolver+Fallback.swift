//
//  MirageHostWallpaperResolver+Fallback.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/19/26.
//
//  Fallback wallpaper resolution helpers.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MirageKit

@MainActor
extension MirageHostWallpaperResolver {
    static func configuredDesktopImagePayload(
        for displayID: CGDirectDisplayID,
        preferredMaxPixelWidth: Int,
        preferredMaxPixelHeight: Int
    ) -> Payload? {
        guard let screen = screen(for: displayID) else {
            MirageLogger.host("Host wallpaper fallback unavailable: no screen for displayID \(displayID)")
            return nil
        }

        guard let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
            MirageLogger.host("Host wallpaper fallback unavailable: no configured desktop image URL")
            return nil
        }

        guard let source = CGImageSourceCreateWithURL(wallpaperURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            MirageLogger.host(
                "Host wallpaper fallback unavailable: failed to load configured desktop image \(wallpaperURL.lastPathComponent)"
            )
            return nil
        }

        guard let payload = payload(
            from: image,
            preferredMaxPixelWidth: preferredMaxPixelWidth,
            preferredMaxPixelHeight: preferredMaxPixelHeight
        ) else {
            MirageLogger.host(
                "Host wallpaper fallback unavailable: failed to encode configured desktop image " +
                    "\(image.width)x\(image.height)"
            )
            return nil
        }

        MirageLogger.host(
            "Host wallpaper fallback loaded configured desktop image bytes=\(payload.imageData.count) " +
                "size=\(payload.pixelWidth)x\(payload.pixelHeight)"
        )
        return payload
    }

    static func logWallpaperWindowResolutionFailure(
        primaryDisplayID: CGDirectDisplayID,
        displayFrame: CGRect,
        candidates: [WallpaperWindowCandidate]
    ) {
        let wallpaperCandidates = candidates
            .filter { $0.ownerName == "Dock" || $0.title.localizedCaseInsensitiveContains("wallpaper") }
            .prefix(5)
            .map { candidate in
                "\(candidate.ownerName)/\(candidate.title) layer=\(candidate.windowLayer) frame=\(formattedRect(candidate.frame))"
            }
            .joined(separator: "; ")

        MirageLogger.host(
            "Host wallpaper SCK window unavailable displayID=\(primaryDisplayID) " +
                "displayFrame=\(formattedRect(displayFrame)) windows=\(candidates.count) " +
                "wallpaperCandidates=[\(wallpaperCandidates)]"
        )
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }
    }

    private static func formattedRect(_ rect: CGRect) -> String {
        String(
            format: "x=%.0f y=%.0f w=%.0f h=%.0f",
            Double(rect.origin.x),
            Double(rect.origin.y),
            Double(rect.width),
            Double(rect.height)
        )
    }
}
#endif
