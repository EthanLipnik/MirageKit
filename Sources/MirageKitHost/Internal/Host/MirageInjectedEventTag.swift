//
//  MirageInjectedEventTag.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/5/26.
//
//  Tags injected events so local input blocking can distinguish them.
//

import CoreGraphics
import Foundation

#if os(macOS)
enum MirageInjectedEventTag {
    private static let userData: Int64 = 0x4D4952414745

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }

    static func isInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == userData
    }

    static func postSession(_ event: CGEvent) {
        mark(event)
        event.post(tap: .cgSessionEventTap)
    }

    static func postHID(_ event: CGEvent) {
        mark(event)
        event.post(tap: .cghidEventTap)
    }
}
#endif
