//
//  WeakSendableBox.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
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

/// Weak object reference that can cross `@Sendable` closure boundaries without retaining its target.
final class WeakSendableBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
