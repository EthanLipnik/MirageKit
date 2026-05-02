//
//  MirageClientService+MessageHandling+HostScreenshot.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/2/26.
//
//  Host screenshot result handling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func handleHostScreenshotResult(_ message: ControlMessage) {
        do {
            let result = try message.decode(HostScreenshotResultMessage.self)
            onHostScreenshotResult?(result)
        } catch {
            MirageLogger.error(.client, error: error, message: "Failed to decode host screenshot result: ")
        }
    }
}
