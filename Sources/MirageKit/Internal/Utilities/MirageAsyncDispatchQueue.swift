//
//  MirageAsyncDispatchQueue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation

package final class MirageAsyncDispatchQueue<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Element>.Continuation?
    private let workerTask: Task<Void, Never>

    package init(
        priority: TaskPriority? = nil,
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded,
        handler: @escaping @Sendable (Element) async -> Void
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self,
            bufferingPolicy: bufferingPolicy
        )
        self.continuation = continuation
        workerTask = Task(priority: priority) {
            for await element in stream {
                await handler(element)
            }
        }
    }

    deinit {
        finish()
    }

    package func yield(_ element: Element) {
        lock.lock()
        let continuationSnapshot = continuation
        lock.unlock()
        continuationSnapshot?.yield(element)
    }

    package func finish() {
        lock.lock()
        let continuationSnapshot = continuation
        continuation = nil
        lock.unlock()
        continuationSnapshot?.finish()
        workerTask.cancel()
    }
}
