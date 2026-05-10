//
//  MirageRenderSerialWorker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Serial worker used by the client render hot path.
//

import Dispatch
import Foundation

final class MirageRenderSerialWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()

    init(label: String, qos: DispatchQoS = .userInteractive) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: key, value: ())
    }

    var dispatchQueue: DispatchQueue {
        queue
    }

    func submit(_ block: @escaping @Sendable () -> Void) {
        queue.async(execute: block)
    }

    @discardableResult
    func sync<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) != nil {
            return try block()
        }
        return try queue.sync(execute: block)
    }
}
