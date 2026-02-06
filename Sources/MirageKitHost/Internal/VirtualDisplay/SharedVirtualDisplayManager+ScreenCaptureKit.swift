//
//  SharedVirtualDisplayManager+ScreenCaptureKit.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension SharedVirtualDisplayManager {
    // MARK: - ScreenCaptureKit Integration

    /// Find the SCDisplay corresponding to the shared virtual display
    func findSCDisplay(maxAttempts: Int = 8) async throws -> SCDisplayWrapper {
        guard let displayID = sharedDisplay?.displayID else { throw SharedDisplayError.noActiveDisplay }
        return try await findSCDisplay(displayID: displayID, maxAttempts: maxAttempts)
    }

    /// Find the SCDisplay for a specific displayID.
    func findSCDisplay(displayID: CGDirectDisplayID, maxAttempts: Int = 8) async throws -> SCDisplayWrapper {
        var attempt = 0
        var delayMs = 120

        while attempt < maxAttempts {
            attempt += 1

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                if let scDisplay = content.displays.first(where: { $0.displayID == displayID }) {
                    MirageLogger
                        .host(
                            "Found SCDisplay \(displayID): \(scDisplay.width)x\(scDisplay.height) (attempt \(attempt)/\(maxAttempts))"
                        )
                    return SCDisplayWrapper(display: scDisplay)
                }

                if attempt < maxAttempts {
                    MirageLogger
                        .host(
                            "SCDisplay not yet available for displayID \(displayID) (attempt \(attempt)/\(maxAttempts)); retrying in \(delayMs)ms"
                        )
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    delayMs = min(1000, Int(Double(delayMs) * 1.6))
                } else {
                    let available = content.displays.map(\.displayID)
                    MirageLogger.error(
                        .host,
                        "SCDisplay not found for displayID \(displayID) after \(maxAttempts) attempts. Available: \(available)"
                    )
                }
            } catch {
                if attempt < maxAttempts {
                    MirageLogger.error(
                        .host,
                        "Failed to query SCShareableContent for displayID \(displayID) (attempt \(attempt)/\(maxAttempts)): \(error)"
                    )
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    delayMs = min(1000, Int(Double(delayMs) * 1.6))
                    continue
                }
                throw error
            }
        }

        throw SharedDisplayError.scDisplayNotFound(displayID)
    }

    /// Find the SCDisplay for the main display (used for login display streaming).
    func findMainSCDisplay() async throws -> SCDisplayWrapper {
        let mainDisplayID = CGMainDisplayID()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let scDisplay = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            MirageLogger.error(
                .host,
                "Main SCDisplay not found for displayID \(mainDisplayID). Available: \(content.displays.map(\.displayID))"
            )
            throw SharedDisplayError.scDisplayNotFound(mainDisplayID)
        }

        MirageLogger.host("Found main SCDisplay \(mainDisplayID): \(scDisplay.width)x\(scDisplay.height)")
        return SCDisplayWrapper(display: scDisplay)
    }
}
#endif
