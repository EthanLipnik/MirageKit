//
//  WeakSendableBox.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import Foundation

/// Weak object reference that can cross `@Sendable` closure boundaries without retaining its target.
final class WeakSendableBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}
