//
//  WindowCaptureEngine+RestartResolution.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Capture restart resolution helpers.
//

import Foundation

#if os(macOS)
import ScreenCaptureKit
import CoreGraphics

extension WindowCaptureEngine {
    private func ownerPID(for windowID: WindowID) -> pid_t? {
        let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]]
        return windowList?.first?[kCGWindowOwnerPID] as? pid_t
    }

    func resolveCaptureTargetsForRestart(
        config: CaptureSessionConfiguration,
        mode: CaptureMode,
        maxAttempts: Int = 6,
        initialDelayMs: Int = 80
    ) async -> CaptureSessionConfiguration {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1...attempts {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                let resolvedDisplay = content.displays.first(where: { $0.displayID == config.displayID })
                let resolvedWindow = config.windowID.flatMap { windowID in
                    content.windows.first(where: { $0.windowID == windowID })
                }
                let windowOwnerPID: pid_t? = config.windowID.flatMap { windowID in
                    ownerPID(for: windowID)
                }
                var applicationPIDCandidates: [pid_t] = []
                if let configuredPID = config.applicationPID, configuredPID > 0 {
                    applicationPIDCandidates.append(configuredPID)
                }
                if let windowOwnerPID, windowOwnerPID > 0, windowOwnerPID != config.applicationPID {
                    applicationPIDCandidates.append(windowOwnerPID)
                }
                let resolvedApplication = applicationPIDCandidates.lazy.compactMap { applicationPID in
                    content.applications.first(where: { $0.processID == applicationPID })
                }.first
                let effectiveApplicationPID = resolvedApplication?.processID ?? applicationPIDCandidates.first

                let hasResolvedDisplay = resolvedDisplay != nil
                let hasResolvedWindowTargets: Bool
                switch mode {
                case .window:
                    hasResolvedWindowTargets = resolvedWindow != nil && resolvedApplication != nil
                case .display:
                    hasResolvedWindowTargets = true
                }

                let displayToUse = resolvedDisplay ?? config.display
                let windowToUse = resolvedWindow ?? config.window
                let applicationToUse = resolvedApplication ?? config.application

                let updatedConfig = CaptureSessionConfiguration(
                    windowID: config.windowID,
                    applicationPID: effectiveApplicationPID ?? config.applicationPID,
                    displayID: displayToUse.displayID,
                    window: windowToUse,
                    application: applicationToUse,
                    display: displayToUse,
                    knownScaleFactor: config.knownScaleFactor,
                    outputScale: config.outputScale,
                    resolution: config.resolution,
                    showsCursor: config.showsCursor
                )

                if hasResolvedDisplay && hasResolvedWindowTargets {
                    if attempt > 1 {
                        MirageLogger.capture("Resolved capture targets on attempt \(attempt)/\(attempts) for restart")
                    }
                    return updatedConfig
                }

                if attempt < attempts {
                    let missingParts = [
                        hasResolvedDisplay ? nil : "display",
                        hasResolvedWindowTargets ? nil : "window/application",
                    ].compactMap { $0 }
                    let missingLabel = missingParts.joined(separator: ", ")
                    MirageLogger.capture("Capture restart targets missing (\(missingLabel)) on attempt \(attempt)/\(attempts); retrying in \(delayMs)ms")
                    try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                    delayMs = min(1_000, Int(Double(delayMs) * 1.6))
                }
            } catch {
                if attempt >= attempts {
                    MirageLogger.error(.capture, "Capture restart resolution failed after \(attempts) attempts: \(error)")
                    break
                }
                MirageLogger.error(.capture, "Capture restart resolution error (attempt \(attempt)/\(attempts)): \(error)")
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1_000, Int(Double(delayMs) * 1.6))
            }
        }

        MirageLogger.capture("Capture restart using cached targets")
        return config
    }
}

#endif
