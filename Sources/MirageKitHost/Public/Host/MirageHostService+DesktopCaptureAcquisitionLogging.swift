//
//  MirageHostService+DesktopCaptureAcquisitionLogging.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
#if os(macOS)
extension MirageHostService {
    /// Logs a virtual-display startup attempt when it is a retry or fallback rung.
    nonisolated func logDesktopVirtualDisplayAttempt(_ attempt: DesktopVirtualDisplayStartupAttempt) {
        let attemptResolution = attempt.backingScale.pixelResolution
        if attempt.isCachedTarget {
            MirageLogger.host(
                "Retrying desktop virtual display acquisition with cached startup target: " +
                    "\(Int(attemptResolution.width))x\(Int(attemptResolution.height)) px, " +
                    "\(attempt.refreshRate)Hz, \(attempt.colorSpace.displayName)"
            )
        } else if attempt.fallbackKind == .descriptorFallback {
            MirageLogger.host(
                "Retrying desktop virtual display acquisition with descriptor fallback: " +
                    "\(Int(attemptResolution.width))x\(Int(attemptResolution.height)) px, " +
                    "\(attempt.refreshRate)Hz, \(attempt.colorSpace.displayName)"
            )
        } else if attempt.isConservativeRetry {
            MirageLogger.host(
                "Retrying desktop virtual display acquisition with conservative settings: " +
                    "\(Int(attemptResolution.width))x\(Int(attemptResolution.height)) px, " +
                    "\(attempt.refreshRate)Hz, \(attempt.colorSpace.displayName), 1x backing"
            )
        }
    }

    /// Logs retry selection after a failed virtual-display startup attempt.
    nonisolated func logDesktopVirtualDisplayRetry(
        attempt: DesktopVirtualDisplayStartupAttempt,
        currentIndex: Int,
        nextAttemptIndex: Int,
        startupAttempts: [DesktopVirtualDisplayStartupAttempt],
        error: any Error
    ) {
        if nextAttemptIndex != currentIndex + 1 {
            let skippedAttempts = startupAttempts[(currentIndex + 1) ..< nextAttemptIndex]
                .map(\.label)
                .joined(separator: ", ")
            MirageLogger.host(
                "Desktop virtual display acquisition skipped ineligible retry rung(s) after \(attempt.label): \(skippedAttempts)"
            )
        }
        MirageLogger.host(
            "Desktop virtual display acquisition failed for \(attempt.label); retrying: \(error)"
        )
    }

    /// Logs the terminal fail-closed virtual-display acquisition error.
    nonisolated func logDesktopVirtualDisplayFailClosed(_ error: any Error) {
        if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError,
           case .creationFailed = sharedDisplayError {
            MirageLogger.host(
                "Virtual display acquisition failed for desktop stream; fail-closed policy active: \(error)"
            )
        } else {
            MirageLogger.error(
                .host,
                "Virtual display acquisition failed for desktop stream; fail-closed policy active: \(error)"
            )
        }
    }

    /// Logs a successful cached or conservative virtual-display retry.
    nonisolated func logDesktopVirtualDisplayAttemptSuccess(_ attempt: DesktopVirtualDisplayStartupAttempt) {
        if attempt.isCachedTarget {
            MirageLogger.host(
                "Desktop virtual display cached startup target succeeded for stream startup"
            )
        } else if attempt.isConservativeRetry {
            MirageLogger.host(
                "Desktop virtual display conservative retry succeeded for stream startup"
            )
        }
    }
}
#endif
