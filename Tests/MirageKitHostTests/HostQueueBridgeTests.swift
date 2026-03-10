//
//  HostQueueBridgeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@MainActor
private final class QueueBridgeProbe {
    private(set) var runs = 0

    func recordRun() {
        MainActor.preconditionIsolated()
        runs += 1
    }
}

@Suite("Host Queue Bridge")
struct HostQueueBridgeTests {
    @Test("dispatchMainWork executes host callbacks on the main thread")
    @MainActor
    func dispatchMainWorkExecutesHostCallbacksOnTheMainThread() async {
        let host = MirageHostService()
        let probe = QueueBridgeProbe()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            host.dispatchMainWork(completion: {
                continuation.resume()
            }) {
                probe.recordRun()
            }
        }

        #expect(probe.runs == 1)
    }

    @Test("dispatchControlWork executes host callbacks on the main thread")
    @MainActor
    func dispatchControlWorkExecutesHostCallbacksOnTheMainThread() async {
        let host = MirageHostService()
        let probe = QueueBridgeProbe()
        let clientID = UUID()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            host.dispatchControlWork(clientID: clientID, completion: {
                continuation.resume()
            }) {
                probe.recordRun()
            }
        }

        #expect(probe.runs == 1)
    }
}
#endif
