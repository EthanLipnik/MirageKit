//
//  MirageSignpost.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import os

package enum MirageSignpost {
    private static let subsystem = "com.mirage"
    private static let log = OSLog(subsystem: subsystem, category: "performance")
    private static let signposter = OSSignposter(logHandle: log)
    private static let enabled: Bool = MirageEnvironmentValue.isTruthy(
        ProcessInfo.processInfo.environment["MIRAGE_SIGNPOST"]
    )

    package static func emitEvent(_ name: StaticString) {
        guard enabled else { return }
        signposter.emitEvent(name)
    }
}
