//
//  GlobalDecodeBudgetControllerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

#if os(macOS)
@Suite("Global Decode Budget Controller", .serialized)
struct GlobalDecodeBudgetControllerTests {
    @Test("Unregister resumes queued waiters without a lease")
    func unregisterResumesQueuedWaitersWithoutLease() async throws {
        let controller = GlobalDecodeBudgetController()
        let activeStreams: [StreamID] = [901, 902, 903, 904]
        let waitingStream: StreamID = 905
        var leases: [GlobalDecodeBudgetController.Lease] = []

        for streamID in activeStreams {
            await controller.register(streamID: streamID, tier: .activeLive)
            let lease = try #require(await controller.acquire(streamID: streamID))
            leases.append(lease)
        }

        await controller.register(streamID: waitingStream, tier: .activeLive)
        let waitingTask = Task {
            await controller.acquire(streamID: waitingStream)
        }
        try await Task.sleep(for: .milliseconds(50))

        await controller.unregister(streamID: waitingStream)
        let cancelledLease = await waitingTask.value
        #expect(cancelledLease == nil)

        for lease in leases {
            await controller.release(lease)
        }
        for streamID in activeStreams {
            await controller.unregister(streamID: streamID)
        }
    }

    @Test("Unregistered streams cannot acquire decode budget leases")
    func unregisteredStreamsCannotAcquireDecodeBudgetLeases() async {
        let controller = GlobalDecodeBudgetController()
        let streamID: StreamID = 906

        #expect(await controller.acquire(streamID: streamID) == nil)

        await controller.register(streamID: streamID, tier: .activeLive)
        let lease = await controller.acquire(streamID: streamID)
        #expect(lease != nil)
        await controller.unregister(streamID: streamID)

        #expect(await controller.acquire(streamID: streamID) == nil)
    }
}
#endif
