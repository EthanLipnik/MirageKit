//
//  HostScreenshotCapturer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Host-side ScreenCaptureKit screenshot capture and PNG persistence.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MirageKit
import ScreenCaptureKit
import UniformTypeIdentifiers

struct HostScreenshotCaptureTarget: Sendable, Equatable {
    enum Filter: Sendable, Equatable {
        case display(displayID: CGDirectDisplayID, includedWindowIDs: [CGWindowID], sourceRect: CGRect?)
        case window(windowID: CGWindowID, displayID: CGDirectDisplayID?)
    }

    let filter: Filter
    let source: MirageHostScreenshotSource
}

struct HostScreenshotSavedFile: Sendable, Equatable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: UInt64
}

enum HostScreenshotError: LocalizedError {
    case noCaptureTarget
    case displayUnavailable(CGDirectDisplayID)
    case windowUnavailable(CGWindowID)
    case captureReturnedNoImage
    case destinationUnavailable
    case imageDestinationUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .noCaptureTarget:
            return "No host display is available for screenshots."
        case let .displayUnavailable(displayID):
            return "Display \(displayID) is unavailable for screenshot capture."
        case let .windowUnavailable(windowID):
            return "Window \(windowID) is unavailable for screenshot capture."
        case .captureReturnedNoImage:
            return "ScreenCaptureKit returned no screenshot image."
        case .destinationUnavailable:
            return "The screenshot destination is unavailable."
        case .imageDestinationUnavailable:
            return "Could not create a PNG image destination."
        case .pngEncodingFailed:
            return "Could not encode the screenshot as PNG."
        }
    }
}

@MainActor
enum HostScreenshotCapturer {
    static func captureAndSave(
        target: HostScreenshotCaptureTarget,
        capturedAt: Date = Date()
    ) async throws -> HostScreenshotSavedFile {
        let resolved = try await resolvedFilter(for: target)
        let image = try await captureImage(
            filter: resolved.filter,
            sourceRect: resolved.sourceRect
        )
        return try HostScreenshotStore.save(image, capturedAt: capturedAt)
    }

    nonisolated static func primaryPhysicalDisplayTarget(
        primaryDisplayID: CGDirectDisplayID?
    ) -> HostScreenshotCaptureTarget? {
        guard let displayID = primaryDisplayID else { return nil }
        return HostScreenshotCaptureTarget(
            filter: .display(displayID: displayID, includedWindowIDs: [], sourceRect: nil),
            source: .primaryPhysicalDisplay
        )
    }

    private static func resolvedFilter(
        for target: HostScreenshotCaptureTarget
    ) async throws -> (filter: SCContentFilter, sourceRect: CGRect?) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        switch target.filter {
        case let .display(displayID, includedWindowIDs, sourceRect):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw HostScreenshotError.displayUnavailable(displayID)
            }
            let includedWindowIDSet = Set(includedWindowIDs)
            let includedWindows = content.windows.filter { includedWindowIDSet.contains($0.windowID) }
            let filter = includedWindows.isEmpty
                ? SCContentFilter(display: display, excludingWindows: [])
                : SCContentFilter(display: display, including: includedWindows)
            return (filter, sourceRect)

        case let .window(windowID, _):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw HostScreenshotError.windowUnavailable(windowID)
            }
            return (SCContentFilter(desktopIndependentWindow: window), nil)
        }
    }

    private static func captureImage(
        filter: SCContentFilter,
        sourceRect: CGRect?
    ) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        if let sourceRect = normalizedSourceRect(sourceRect) {
            configuration.sourceRect = sourceRect
        }

        let outputSize = outputPixelSize(for: filter, sourceRect: sourceRect)
        configuration.width = outputSize.width
        configuration.height = outputSize.height

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let image else {
                    continuation.resume(throwing: HostScreenshotError.captureReturnedNoImage)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private static func outputPixelSize(
        for filter: SCContentFilter,
        sourceRect: CGRect?
    ) -> (width: Int, height: Int) {
        let info = SCShareableContent.info(for: filter)
        let pointPixelScale = max(CGFloat(info.pointPixelScale), 1)
        let sourceSize = normalizedSourceRect(sourceRect)?.size ?? info.contentRect.standardized.size
        return (
            width: max(1, Int(ceil(sourceSize.width * pointPixelScale))),
            height: max(1, Int(ceil(sourceSize.height * pointPixelScale)))
        )
    }

    private static func normalizedSourceRect(_ sourceRect: CGRect?) -> CGRect? {
        guard let sourceRect else { return nil }
        let normalized = sourceRect.standardized
        guard normalized.width > 0, normalized.height > 0 else { return nil }
        return normalized
    }
}

enum HostScreenshotStore {
    nonisolated static let screenshotDefaultsSuiteName = "com.apple.screencapture"

    static func save(
        _ image: CGImage,
        capturedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> HostScreenshotSavedFile {
        let directory = try resolvedDestinationDirectory(fileManager: fileManager)
        let url = uniqueScreenshotURL(
            in: directory,
            capturedAt: capturedAt,
            fileManager: fileManager
        )
        try writePNG(image, to: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return HostScreenshotSavedFile(
            url: url,
            pixelWidth: image.width,
            pixelHeight: image.height,
            byteCount: byteCount
        )
    }

    static func resolvedDestinationDirectory(
        screenshotLocation: String? = screenshotLocation(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let desktopDirectory = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        let fallbackDirectory = desktopDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop", isDirectory: true)

        if let screenshotLocation,
           let preferredDirectory = expandedDirectoryURL(
               screenshotLocation,
               fileManager: fileManager
           ) {
            return preferredDirectory
        }

        guard directoryExists(fallbackDirectory, fileManager: fileManager) else {
            throw HostScreenshotError.destinationUnavailable
        }
        return fallbackDirectory
    }

    nonisolated static func uniqueScreenshotURL(
        in directory: URL,
        capturedAt: Date,
        fileManager: FileManager = .default
    ) -> URL {
        let baseName = "Mirage Screenshot \(fileTimestamp(capturedAt))"
        var candidate = directory.appendingPathComponent("\(baseName).png", isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(suffix).png", isDirectory: false)
            suffix += 1
        }
        return candidate
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw HostScreenshotError.imageDestinationUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HostScreenshotError.pngEncodingFailed
        }
    }

    private static func screenshotLocation() -> String? {
        UserDefaults(suiteName: screenshotDefaultsSuiteName)?.string(forKey: "location")
    }

    private static func expandedDirectoryURL(
        _ path: String,
        fileManager: FileManager
    ) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath, isDirectory: true)
        guard directoryExists(url, fileManager: fileManager) else { return nil }
        return url
    }

    private static func directoryExists(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
#endif
