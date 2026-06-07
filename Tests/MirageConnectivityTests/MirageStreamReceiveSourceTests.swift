//
//  MirageStreamReceiveSourceTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import Foundation
@testable import MirageConnectivity
import Testing

@Suite("Mirage Stream Receive Source")
struct MirageStreamReceiveSourceTests {
    @Test("Async stream chunks are delivered in order before completion")
    func asyncStreamChunksDeliverInOrderBeforeCompletion() async {
        let stream = AsyncStream<Data>.makeStream(of: Data.self)
        let source = MirageStreamReceiveSource(stream: stream.stream)

        stream.continuation.yield(Data([0x01]))
        stream.continuation.yield(Data([0x02, 0x03]))
        stream.continuation.finish()

        let first = await receive(source)
        let second = await receive(source)
        let completion = await receive(source)

        #expect(first.data == Data([0x01]))
        #expect(!first.isComplete)
        #expect(!first.hasError)
        #expect(second.data == Data([0x02, 0x03]))
        #expect(!second.isComplete)
        #expect(!second.hasError)
        #expect(completion.data == nil)
        #expect(completion.isComplete)
        #expect(!completion.hasError)
    }

    @Test("Pending receive resumes when next stream chunk arrives")
    func pendingReceiveResumesWhenNextStreamChunkArrives() async {
        let stream = AsyncStream<Data>.makeStream(of: Data.self)
        let source = MirageStreamReceiveSource(stream: stream.stream)

        let pendingReceive = Task {
            await receive(source)
        }

        stream.continuation.yield(Data([0x04]))

        let result = await pendingReceive.value
        #expect(result.data == Data([0x04]))
        #expect(!result.isComplete)
        #expect(!result.hasError)
    }

    private func receive(_ source: MirageStreamReceiveSource) async -> ReceivedChunk {
        await withCheckedContinuation { continuation in
            source.receiveNext { data, _, isComplete, error in
                continuation.resume(
                    returning: ReceivedChunk(
                        data: data,
                        isComplete: isComplete,
                        hasError: error != nil
                    )
                )
            }
        }
    }

    private struct ReceivedChunk: Sendable {
        var data: Data?
        var isComplete: Bool
        var hasError: Bool
    }
}
#endif
