//
//  MirageStreamReceiveSource.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import Network

#if os(macOS)
/// Adapts Loom's async byte stream to the callback-based receive shape used by `HostReceiveLoop`.
final class MirageStreamReceiveSource: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferedChunks: [Data] = []
    private var waitingCompletion: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
    private var finished = false

    init(stream: AsyncStream<Data>) {
        Task {
            for await chunk in stream {
                self.push(chunk)
            }
            self.finish()
        }
    }

    /// Delivers the next queued chunk or parks `completion` until new bytes arrive.
    func receiveNext(
        _ completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
    ) {
        let result: (chunk: Data?, isComplete: Bool)?
        lock.lock()
        if !bufferedChunks.isEmpty {
            let chunk = bufferedChunks.removeFirst()
            result = (chunk, false)
        } else if finished {
            result = (nil, true)
        } else {
            waitingCompletion = completion
            result = nil
        }
        lock.unlock()

        if let result {
            completion(result.chunk, nil, result.isComplete, nil)
        }
    }

    /// Adds a new chunk or resumes the parked receive completion immediately.
    private func push(_ chunk: Data) {
        let completionToResume: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
        lock.lock()
        if let waitingCompletion {
            self.waitingCompletion = nil
            completionToResume = waitingCompletion
        } else {
            bufferedChunks.append(chunk)
            completionToResume = nil
        }
        lock.unlock()

        completionToResume?(chunk, nil, false, nil)
    }

    /// Marks the stream complete and resumes any parked receive completion.
    private func finish() {
        let completionToResume: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
        lock.lock()
        finished = true
        completionToResume = waitingCompletion
        waitingCompletion = nil
        lock.unlock()
        completionToResume?(nil, nil, true, nil)
    }
}
#endif
