//
//  MirageHostService+DesktopCaptureUtilities.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension MirageHostService {
    #if DEBUG
    private static let desktopCapturePressureProfileOverride =
        WindowCaptureEngine.CapturePressureProfile.parse(
            ProcessInfo.processInfo.environment["MIRAGE_CAPTURE_PRESSURE_PROFILE"]
        )
    #endif

    /// Resolves the capture pressure profile, allowing debug builds to override it from the environment.
    func resolvedDesktopCapturePressureProfile() -> WindowCaptureEngine.CapturePressureProfile {
        #if DEBUG
        if let desktopCapturePressureProfileOverride = Self.desktopCapturePressureProfileOverride {
            return desktopCapturePressureProfileOverride
        }
        #endif
        return .baseline
    }

    /// Stops active app/window streams before desktop streaming takes exclusive ownership.
    func stopAllStreamsForDesktopMode() async {
        MirageLogger.host("Stopping all streams for desktop mode")

        let sessions = await appStreamManager.allSessions()
        let windowStreams = activeStreams

        for session in windowStreams {
            MirageLogger.host("Stopping window stream: \(session.id)")
            await stopStream(session, minimizeWindow: false, updateAppSession: false)
        }

        for session in sessions {
            MirageLogger.host("Ending app session: \(session.bundleIdentifier)")
            await appStreamManager.endSession(bundleIdentifier: session.bundleIdentifier)
        }

        await restoreStageManagerAfterAppStreamingIfNeeded()
    }

    /// Resolves the virtual display's ScreenCaptureKit display using the shared startup retry policy.
    func findSCDisplayWithRetry(
        maxAttempts: Int,
        startupBudget: DesktopVirtualDisplayStartupBudget? = nil
    )
    async throws -> SCDisplayWrapper {
        let resolvedAttempts = max(maxAttempts, 12)
        do {
            let scDisplay = try await SharedVirtualDisplayManager.shared.findSCDisplay(
                maxAttempts: resolvedAttempts,
                startupBudget: startupBudget
            )
            MirageLogger.host("Found SCDisplay using shared startup policy (attempt budget \(resolvedAttempts))")
            return scDisplay
        } catch {
            MirageLogger.host("Failed to find SCDisplay using shared startup policy after \(resolvedAttempts) attempts")
            throw error
        }
    }

    /// Resolves the main ScreenCaptureKit display for capture warmup.
    func findMainSCDisplayWithRetry(maxAttempts: Int, delayMs: UInt64) async throws -> SCDisplayWrapper {
        for attempt in 1 ... maxAttempts {
            do {
                let scDisplay = try await SharedVirtualDisplayManager.shared.findMainSCDisplay()
                MirageLogger.host("Found main SCDisplay on attempt \(attempt)")
                return scDisplay
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                } else {
                    MirageLogger.host("Failed to find main SCDisplay after \(maxAttempts) attempts")
                    throw error
                }
            }
        }
        throw MirageError.protocolError("Failed to find main SCDisplay")
    }

    /// Builds a non-Mirage host-display capture fallback when virtual-display capture cannot be used.
    func mainDisplayDesktopCaptureFallback(
        reason: String,
        maxAttempts: Int = 8,
        delayMs: UInt64 = 80
    )
    async throws -> DesktopMainDisplayCaptureFallback {
        guard let fallbackDisplayID = resolvePrimaryNonMirageDisplayID() else {
            MirageLogger.host(
                "Desktop capture fallback unavailable: no non-Mirage displays are online, reason=\(reason)"
            )
            throw MirageError.protocolError("Main display fallback unavailable because only Mirage displays are online")
        }

        var display: SCDisplayWrapper?
        for attempt in 1 ... maxAttempts {
            do {
                display = try await SharedVirtualDisplayManager.shared.findSCDisplay(
                    displayID: fallbackDisplayID,
                    maxAttempts: 1
                )
                MirageLogger.host("Found fallback SCDisplay \(fallbackDisplayID) on attempt \(attempt)")
                break
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                } else {
                    MirageLogger.host(
                        "Failed to find fallback SCDisplay \(fallbackDisplayID) after \(maxAttempts) attempts"
                    )
                    throw error
                }
            }
        }

        guard let display else {
            throw MirageError.protocolError("Failed to find fallback SCDisplay \(fallbackDisplayID)")
        }
        let displayID = display.display.displayID
        guard !CGVirtualDisplayBridge.isMirageDisplay(displayID) else {
            MirageLogger.host(
                "Desktop capture fallback rejected Mirage display \(displayID), reason=\(reason)"
            )
            throw MirageError.protocolError("Main display fallback resolved to a Mirage display")
        }
        let bounds = CGDisplayBounds(displayID)
        let pixelWidth = CGDisplayPixelsWide(displayID)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        let resolution = if pixelWidth > 0, pixelHeight > 0 {
            CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        } else {
            CGSize(
                width: CGFloat(display.display.width),
                height: CGFloat(display.display.height)
            )
        }
        guard resolution.width > 0, resolution.height > 0 else {
            throw MirageError.protocolError("Main display fallback has invalid capture resolution")
        }

        let scaleFactor: CGFloat = if bounds.width > 0, bounds.height > 0 {
            max(1.0, max(resolution.width / bounds.width, resolution.height / bounds.height))
        } else {
            1.0
        }
        MirageLogger.host(
            "Desktop capture fallback using main display \(displayID): " +
                "\(Int(resolution.width))x\(Int(resolution.height)) px, reason=\(reason)"
        )
        return DesktopMainDisplayCaptureFallback(
            display: display,
            resolution: resolution,
            displayID: displayID,
            bounds: bounds,
            scaleFactor: scaleFactor
        )
    }
}

#endif
