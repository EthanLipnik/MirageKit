//
//  WindowCaptureEngine+HostScreenshot.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Screenshot target snapshots for active host streams.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension WindowCaptureEngine {
    func hostScreenshotCaptureTarget(
        style: MirageHostScreenshotStyle
    ) -> HostScreenshotCaptureTarget? {
        guard let config = captureSessionConfig else { return nil }

        switch style {
        case .fullScreen:
            return HostScreenshotCaptureTarget(
                filter: .display(
                    displayID: config.displayID,
                    includedWindowIDs: [],
                    sourceRect: nil
                ),
                source: .activeStreamDisplay
            )

        case .selection:
            if captureMode == .window,
               let windowID = config.windowID {
                return HostScreenshotCaptureTarget(
                    filter: .window(
                        windowID: CGWindowID(windowID),
                        displayID: config.displayID
                    ),
                    source: .activeStreamSelection
                )
            }

            let includedWindowIDs = config.includedWindows.map(\.windowID)
            let sourceRect = config.sourceRect?.standardized
            if !includedWindowIDs.isEmpty || sourceRect?.isEmpty == false {
                return HostScreenshotCaptureTarget(
                    filter: .display(
                        displayID: config.displayID,
                        includedWindowIDs: includedWindowIDs,
                        sourceRect: sourceRect
                    ),
                    source: .activeStreamSelection
                )
            }

            return HostScreenshotCaptureTarget(
                filter: .display(
                    displayID: config.displayID,
                    includedWindowIDs: [],
                    sourceRect: nil
                ),
                source: .activeStreamDisplay
            )
        }
    }
}
#endif
