//
//  StreamContext+HostScreenshot.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Active stream screenshot target resolution.
//

import Foundation
import MirageKit

#if os(macOS)

extension StreamContext {
    func hostScreenshotCaptureTarget(
        style: MirageHostScreenshotStyle
    ) async -> HostScreenshotCaptureTarget? {
        guard let captureEngine else { return nil }
        return await captureEngine.hostScreenshotCaptureTarget(style: style)
    }
}
#endif
