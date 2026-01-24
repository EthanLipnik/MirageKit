//
//  MirageSignpost.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation
import os

enum MirageSignpost {
    typealias IntervalState = OSSignpostIntervalState

    private static let subsystem = "com.mirage"
    private static let log = OSLog(subsystem: subsystem, category: "performance")
    private static let signposter = OSSignposter(logHandle: log)
    private static let enabled: Bool = {
        ProcessInfo.processInfo.environment["MIRAGE_SIGNPOST"] == "1"
    }()

    static func beginInterval(_ name: StaticString) -> IntervalState? {
        guard enabled else { return nil }
        return signposter.beginInterval(name)
    }

    static func endInterval(_ name: StaticString, _ state: IntervalState?) {
        guard enabled, let state else { return }
        signposter.endInterval(name, state)
    }

    static func emitEvent(_ name: StaticString) {
        guard enabled else { return }
        signposter.emitEvent(name)
    }
}
