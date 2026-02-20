//
//  SerialWorker.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//

import Dispatch
import Foundation

#if os(macOS)
/// Serial queue helper with queue-key assertions.
final class SerialWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: key, value: ())
    }

    var dispatchQueue: DispatchQueue { queue }

    func submit(_ block: @escaping @Sendable () -> Void) {
        queue.async(execute: block)
    }

    func submit(after delay: DispatchTimeInterval, _ block: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: block)
    }

    @discardableResult
    func sync<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) != nil {
            return try block()
        }
        return try queue.sync(execute: block)
    }

    func assertOnQueue(file: StaticString = #fileID, line: UInt = #line) {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
#endif
