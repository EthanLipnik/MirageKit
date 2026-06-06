//
//  MirageHostService+DesktopCaptureUtilities.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

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
            let captureDisplay = try await platformVirtualDisplayBackend.findCaptureDisplay(
                maxAttempts: resolvedAttempts,
                startupBudget: startupBudget
            )
            let display = try await resolveSCDisplayWrapper(
                for: captureDisplay,
                label: "shared startup policy"
            )
            MirageLogger.host("Found SCDisplay using shared startup policy (attempt budget \(resolvedAttempts))")
            return display
        } catch {
            MirageLogger.host("Failed to find SCDisplay using shared startup policy after \(resolvedAttempts) attempts")
            throw error
        }
    }

    /// Resolves a ScreenCaptureKit display wrapper through the current capture-content backend.
    func resolveSCDisplayWrapper(
        for captureDisplay: MirageHostCaptureDisplay,
        label: String,
        maxAttempts: Int = 12,
        initialDelayMs: Int = 80
    )
    async throws -> SCDisplayWrapper {
        try await resolveSCDisplayWrapper(
            displayID: captureDisplay.displayID,
            label: label,
            maxAttempts: maxAttempts,
            initialDelayMs: initialDelayMs
        )
    }

    /// Resolves a ScreenCaptureKit display wrapper by display ID through the current capture-content backend.
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
            let content = try await platformCaptureContentProviderBackend.shareableContent()
            if let displayWrapper = content.displayWrapper(for: displayID) {
                if attempt > 1 {
                    MirageLogger.host("Resolved SCDisplay \(displayID) on attempt \(attempt) (\(label))")
                }
                return displayWrapper
            }
            if attempt < attempts {
                try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            } else {
                let isOnline = CGDisplayIsOnline(displayID) != 0
                MirageLogger.host(
                    "Unable to resolve SCDisplay \(displayID) after \(attempts) attempts (\(label)). " +
                        "CGDisplayIsOnline=\(isOnline), available SCK displays: \(content.displayIDs)"
                )
            }
        }
        throw MirageCore.MirageError.protocolError("Unable to resolve SCDisplay \(displayID) (\(label))")
    }

    /// Resolves the main ScreenCaptureKit display for capture warmup.
    func findMainSCDisplayWithRetry(maxAttempts: Int, delayMs: UInt64) async throws -> SCDisplayWrapper {
        for attempt in 1 ... maxAttempts {
            do {
                let captureDisplay = try await platformVirtualDisplayBackend.findMainCaptureDisplay()
                let display = try await resolveSCDisplayWrapper(
                    for: captureDisplay,
                    label: "main display warmup",
                    maxAttempts: 1,
                    initialDelayMs: Int(delayMs)
                )
                MirageLogger.host("Found main SCDisplay on attempt \(attempt)")
                return display
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(for: .milliseconds(Int64(delayMs)))
                } else {
                    MirageLogger.host("Failed to find main SCDisplay after \(maxAttempts) attempts")
                    throw error
                }
            }
        }
        throw MirageCore.MirageError.protocolError("Failed to find main SCDisplay")
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
            throw MirageCore.MirageError.protocolError("Main display fallback unavailable because only Mirage displays are online")
        }

        var display: SCDisplayWrapper?
        var captureDisplayValue: MirageHostCaptureDisplay?
        for attempt in 1 ... maxAttempts {
            do {
                let captureDisplay = try await platformVirtualDisplayBackend.findCaptureDisplay(
                    displayID: fallbackDisplayID,
                    maxAttempts: 1,
                    startupBudget: nil
                )
                display = try await resolveSCDisplayWrapper(
                    for: captureDisplay,
                    label: "main display fallback",
                    maxAttempts: 1,
                    initialDelayMs: Int(delayMs)
                )
                captureDisplayValue = captureDisplay
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
            throw MirageCore.MirageError.protocolError("Failed to find fallback SCDisplay \(fallbackDisplayID)")
        }
        let displayID = display.display.displayID
        guard !platformVirtualDisplayBackend.isMirageDisplay(displayID) else {
            MirageLogger.host(
                "Desktop capture fallback rejected Mirage display \(displayID), reason=\(reason)"
            )
            throw MirageCore.MirageError.protocolError("Main display fallback resolved to a Mirage display")
        }
        let bounds = CGDisplayBounds(displayID)
        let pixelWidth = CGDisplayPixelsWide(displayID)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        let resolution = if pixelWidth > 0, pixelHeight > 0 {
            CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        } else if let captureDisplayValue, captureDisplayValue.pixelSize.width > 0,
                  captureDisplayValue.pixelSize.height > 0 {
            captureDisplayValue.pixelSize
        } else {
            CGSize(
                width: CGFloat(display.display.width),
                height: CGFloat(display.display.height)
            )
        }
        guard resolution.width > 0, resolution.height > 0 else {
            throw MirageCore.MirageError.protocolError("Main display fallback has invalid capture resolution")
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
