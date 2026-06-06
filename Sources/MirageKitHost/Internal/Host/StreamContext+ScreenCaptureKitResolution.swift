//
//  StreamContext+ScreenCaptureKitResolution.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    /// Iteratively resizes a host window until its accepted frame approximates the requested aspect ratio.
    func iterativelyResizeWindow(
        windowID: WindowID,
        targetSize: CGSize,
        aspectRatio: CGFloat?,
        maxBounds: CGSize,
        placementBounds: CGRect? = nil,
        label: String
    ) async -> CGRect {
        let ar = aspectRatio ?? (targetSize.width / max(1, targetSize.height))
        var candidateW = targetSize.width
        var candidateH = targetSize.height
        let maxAttempts = 6
        var lastResolvedFrame = Self.queryWindowFrame(windowID)?.standardized ?? .zero
        var retriedCenteredTargetAfterMismatch = false

        for attempt in 1 ... maxAttempts {
            let candidate = CGSize(
                width: max(200, candidateW.rounded(.down)),
                height: max(200, candidateH.rounded(.down))
            )
            if let placementBounds, placementBounds.width > 0, placementBounds.height > 0 {
                let targetOrigin = CGPoint(
                    x: placementBounds.minX + floor((placementBounds.width - candidate.width) * 0.5),
                    y: placementBounds.minY + floor((placementBounds.height - candidate.height) * 0.5)
                )
                await WindowSpaceManager.shared.positionWindow(windowID, at: targetOrigin)
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return lastResolvedFrame
                }
            }
            _ = await WindowSpaceManager.shared.resizeWindow(windowID, to: candidate)

            do {
                try await Task.sleep(for: .milliseconds(24))
            } catch {
                return lastResolvedFrame
            }

            guard let windowFrame = Self.queryWindowFrame(windowID) else {
                return lastResolvedFrame
            }

            let actualW = windowFrame.width
            let actualH = windowFrame.height
            lastResolvedFrame = windowFrame.standardized
            let actualAR = actualW / max(1, actualH)
            let arDelta = abs(actualAR - ar) / max(0.001, ar)

            if arDelta < 0.03 {
                MirageLogger.stream(
                    "Window \(windowID) accepted \(Int(actualW))x\(Int(actualH)) at attempt \(attempt) " +
                        "(target AR \(String(format: "%.3f", ar)), actual AR \(String(format: "%.3f", actualAR)), \(label))"
                )
                return lastResolvedFrame
            }

            if attempt < maxAttempts {
                if placementBounds != nil, !retriedCenteredTargetAfterMismatch {
                    retriedCenteredTargetAfterMismatch = true
                    candidateW = targetSize.width
                    candidateH = targetSize.height
                } else {
                    let constrainedBounds = CGRect(
                        origin: .zero,
                        size: CGSize(
                            width: min(maxBounds.width, actualW),
                            height: min(maxBounds.height, actualH)
                        )
                    )
                    let fittedCandidate = Self.aspectFittedFrame(
                        within: constrainedBounds,
                        aspectRatio: ar
                    ).size
                    if abs(fittedCandidate.width - candidate.width) > 1 ||
                        abs(fittedCandidate.height - candidate.height) > 1 {
                        candidateW = fittedCandidate.width
                        candidateH = fittedCandidate.height
                    } else {
                        let shrunkWidth = min(maxBounds.width, max(200, floor(candidate.width * 0.96)))
                        let shrunkHeight = min(maxBounds.height, max(200, floor(shrunkWidth / max(ar, 0.001))))
                        candidateW = shrunkWidth
                        candidateH = shrunkHeight
                    }
                }
                MirageLogger.stream(
                    "Window \(windowID) AR mismatch at \(Int(actualW))x\(Int(actualH)) " +
                        "(target AR \(String(format: "%.3f", ar)), actual \(String(format: "%.3f", actualAR))), " +
                        "retrying \(Int(candidateW))x\(Int(candidateH)) (\(label), attempt \(attempt + 1))"
                )
            }
        }

        return lastResolvedFrame
    }

    /// Queries a window frame through `CGWindowList` without depending on ScreenCaptureKit's window cache.
    static func queryWindowFrame(_ windowID: WindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            return nil
        }
        return CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 0,
            height: boundsDict["Height"] ?? 0
        )
    }

    /// Resolves a ScreenCaptureKit window wrapper, retrying while SCK refreshes its shareable-content list.
    func resolveSCWindowWrapper(
        windowID: WindowID,
        label: String,
        maxAttempts: Int = 10,
        initialDelayMs: Int = 100
    )
    async throws -> SCWindowWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            let content = try await SCShareableContent.mirageHostContent()
            if let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) {
                if attempt > 1 {
                    MirageLogger.stream("Resolved SCWindow \(windowID) on attempt \(attempt) (\(label))")
                }
                return SCWindowWrapper(window: window)
            }
            if attempt < attempts {
                try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(600, Int(Double(delayMs) * 1.5))
            } else {
                let windowDetails = content.windows.map { w in
                    "(\(w.windowID), \(w.owningApplication?.bundleIdentifier ?? "unknown"))"
                }
                MirageLogger.stream(
                    "Unable to resolve SCWindow \(windowID) after \(attempts) attempts (\(label)). " +
                        "Available windows (\(content.windows.count)): \(windowDetails)"
                )
            }
        }
        throw MirageError.protocolError("Unable to resolve SCWindow \(windowID) for stream \(streamID) (\(label))")
    }

    /// Resolves a ScreenCaptureKit display wrapper, retrying while SCK refreshes its shareable-content list.
    func resolveSCDisplayWrapper(
        displayID: CGDirectDisplayID,
        label: String,
        maxAttempts: Int = 12,
        initialDelayMs: Int = 80
    )
    async throws -> SCDisplayWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            let content = try await SCShareableContent.mirageHostContent()
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                if attempt > 1 {
                    MirageLogger.stream("Resolved SCDisplay \(displayID) on attempt \(attempt) (\(label))")
                }
                return SCDisplayWrapper(display: display)
            }
            if attempt < attempts {
                try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            } else {
                let isOnline = CGDisplayIsOnline(displayID) != 0
                let available = content.displays.map(\.displayID)
                MirageLogger.stream(
                    "Unable to resolve SCDisplay \(displayID) after \(attempts) attempts (\(label)). " +
                        "CGDisplayIsOnline=\(isOnline), available SCK displays: \(available)"
                )
            }
        }
        throw MirageError.protocolError("Unable to resolve SCDisplay \(displayID) for stream \(streamID) (\(label))")
    }
}

#endif
