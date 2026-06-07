//
//  ClientLoomTCPFallbackTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKit
import Foundation
import Loom
import Testing
import MirageConnectivity
import MirageWire

#if os(macOS)
extension ClientLoomControlPlaneTests {
    @MainActor
    @Test("TCP fallback sessions keep control traffic and labeled media streams coherent")
    func tcpFallbackSessionKeepsControlAndMediaTrafficCoherent() async throws {
        let pair = try await makeLoopbackControlPair()
        try await pair.startAuthenticatedSessions()

        let serverControlTask = Task {
            try await MirageControlChannel.accept(from: pair.server)
        }
        let clientControl = try await MirageControlChannel.open(on: pair.client)
        let serverControl = try await serverControlTask.value
        let serverReceiver = ControlMessageReceiver(channel: serverControl)
        let incomingStreamsTask = Task<[LoomMultiplexedStream], Never> {
            var streams: [LoomMultiplexedStream] = []
            let observer = pair.server.makeIncomingStreamObserver()
            for await stream in observer {
                guard stream.label == "control/42" || stream.label == "video/42" else { continue }
                streams.append(stream)
                if streams.count == 2 {
                    return streams
                }
            }
            return streams
        }

        let controlStream = try await pair.client.openStream(label: "control/42")
        let videoStream = try await pair.client.openStream(label: "video/42")
        let incomingStreams = await incomingStreamsTask.value
        #expect(incomingStreams.count == 2)
        let serverVideoStream = try #require(incomingStreams.first { $0.label == "video/42" })

        let expectedVideoPayloads = (0 ..< 6).map { Data("video-\($0)".utf8) }
        let receivedVideoTask = Task {
            await collectPayloads(from: serverVideoStream, count: expectedVideoPayloads.count)
        }
        do {
            for index in expectedVideoPayloads.indices {
                try await clientControl.send(MirageWire.ControlMessage(type: .ping))
                let receivedPing = try await serverReceiver.next()
                #expect(receivedPing.type == .ping)

                try await controlStream.send(Data("control-\(index)".utf8))
                try await videoStream.sendUnreliable(expectedVideoPayloads[index])
            }

            try await controlStream.close()
            try await videoStream.close()

            #expect(await receivedVideoTask.value == expectedVideoPayloads)
            #expect(await pair.client.state == .ready)
            #expect(await pair.server.state == .ready)
        } catch {
            try? await controlStream.close()
            try? await videoStream.close()
            await clientControl.cancel()
            await serverControl.cancel()
            await pair.stop()
            throw error
        }

        await clientControl.cancel()
        await serverControl.cancel()
        await pair.stop()
    }
}
#endif
