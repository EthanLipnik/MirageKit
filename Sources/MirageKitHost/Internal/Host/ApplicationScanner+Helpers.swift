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
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers

extension ApplicationScanner {
    func canonicalURL(forPath path: String) -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return url.resolvingSymlinksInPath()
    }

    func runningAppPathsByBundleIdentifier() -> [String: Set<String>] {
        var runningPathsByBundle: [String: Set<String>] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleIdentifier = app.bundleIdentifier?.lowercased(),
                  let bundleURL = app.bundleURL else { continue }
            let canonicalPath = canonicalURL(forPath: bundleURL.path).path
            runningPathsByBundle[bundleIdentifier, default: []].insert(canonicalPath)
        }
        return runningPathsByBundle
    }

    func defaultAppPath(
        forBundleIdentifier bundleIdentifier: String,
        cachedPaths: inout [String: String],
        missingBundleIdentifiers: inout Set<String>
    )
    -> String? {
        if let cachedPath = cachedPaths[bundleIdentifier] { return cachedPath }
        if missingBundleIdentifiers.contains(bundleIdentifier) { return nil }
        guard let defaultURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            missingBundleIdentifiers.insert(bundleIdentifier)
            return nil
        }

        let canonicalPath = canonicalURL(forPath: defaultURL.path).path
        cachedPaths[bundleIdentifier] = canonicalPath
        return canonicalPath
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

    func generateIconPayloadData(
        for url: URL,
        maxPixelSize: Int,
        heifCompressionQuality: Double
    ) async -> Data? {
        let targetSize = CGFloat(max(32, min(512, maxPixelSize)))
        let clampedCompressionQuality = max(0.1, min(1.0, heifCompressionQuality))

        return await MainActor.run {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return Self.rasterizeIconToHEIFOrPNG(
                icon,
                size: targetSize,
                heifCompressionQuality: clampedCompressionQuality
            )
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

    nonisolated static func rasterizeIconToHEIFOrPNG(
        _ icon: NSImage,
        size: CGFloat,
        heifCompressionQuality: Double
    ) -> Data? {
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

        if let cgImage = bitmap.cgImage {
            let mutableData = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) {
                let options: CFDictionary = [
                    kCGImageDestinationLossyCompressionQuality: heifCompressionQuality,
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
}

#endif
