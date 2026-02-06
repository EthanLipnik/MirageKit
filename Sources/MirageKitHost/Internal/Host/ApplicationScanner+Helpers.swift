//
//  ApplicationScanner+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Application scanning helpers.
//

import MirageKit
#if os(macOS)
import AppKit
import CoreServices
import Foundation

// MARK: - Helpers

extension ApplicationScanner {
    func canonicalURL(forPath path: String) -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return url.resolvingSymlinksInPath()
    }

    func domainPriority(for url: URL) -> Int {
        let path = url.path

        if path.hasPrefix("/System/Applications/") || path == "/System/Applications" { return 5 }
        if path.hasPrefix("/System/Cryptexes/App/System/Applications/") { return 5 }
        if path.hasPrefix("/Applications/") || path == "/Applications" { return 4 }
        if path.hasPrefix("/System/Library/CoreServices/") { return 3 }

        let userApplications = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
        if path.hasPrefix(userApplications) { return 2 }

        return 1
    }

    func generateIconPNG(for url: URL) async -> Data? {
        let size = iconSize
        return await MainActor.run {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return Self.rasterizeIconToPNG(icon, size: size)
        }
    }

    nonisolated static func rasterizeIconToPNG(_ icon: NSImage, size: CGFloat) -> Data? {
        let targetSize = NSSize(width: size, height: size)
        let scaledImage = NSImage(size: targetSize)

        scaledImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: icon.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        scaledImage.unlockFocus()

        guard let tiffData = scaledImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

#endif
