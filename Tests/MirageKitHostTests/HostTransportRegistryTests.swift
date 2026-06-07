//
//  HostTransportRegistryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import Foundation
import MirageConnectivity
@testable import MirageKitHost
import Testing
import MirageMedia

@Suite("Host Transport Registry")
struct HostTransportRegistryTests {
    @Test("Audio sends through registered Mirage queued stream")
    func audioSendsThroughRegisteredMirageQueuedStream() {
        let registry = HostTransportRegistry()
        let missingClientID = UUID()
        let missingCompletion = CompletionRecorder()
        registry.sendAudio(
            clientID: missingClientID,
            data: Data([0x00])
        ) { error in
            missingCompletion.record(error)
        }

        let clientID = UUID()
        let stream = FakeQueuedUnreliableMediaStream()
        let payload = Data([0x01, 0x02, 0x03])
        registry.registerAudioStream(stream, clientID: clientID, profile: .interactiveAudio)

        let completion = CompletionRecorder()
        registry.sendAudio(clientID: clientID, data: payload) { error in
            completion.record(error)
        }

        #expect(missingCompletion.errors.count == 1)
        #expect(missingCompletion.errors.first ?? nil == nil)
        #expect(completion.errors.count == 1)
        #expect(completion.errors.first ?? nil == nil)
        #expect(stream.sends == [FakeQueuedUnreliableMediaStream.Send(data: payload, profile: .interactiveAudio)])
        #expect(registry.hasAudioConnection(clientID: clientID))

        registry.unregisterAudioStream(clientID: clientID)
        #expect(!registry.hasAudioConnection(clientID: clientID))
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedErrors: [Error?] = []

    var errors: [Error?] {
        lock.withLock { storedErrors }
    }

    func record(_ error: Error?) {
        lock.withLock {
            storedErrors.append(error)
        }
    }
}

private final class FakeQueuedUnreliableMediaStream: @unchecked Sendable, MirageQueuedUnreliableMediaStream {
    struct Send: Equatable {
        let data: Data
        let profile: MirageMedia.MirageMediaSendProfile
    }

    private let lock = NSLock()
    private var storedSends: [Send] = []

    var sends: [Send] {
        lock.withLock { storedSends }
    }

    func sendUnreliableQueued(
        _ data: Data,
        profile: MirageMedia.MirageMediaSendProfile,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        lock.withLock {
            storedSends.append(Send(data: data, profile: profile))
        }
        onComplete(nil)
    }

    func sendUnreliableQueued(
        _ data: Data,
        profile: MirageMedia.MirageMediaSendProfile,
        options: MirageQueuedUnreliableSendOptions,
        onComplete: @escaping @Sendable (Error?) -> Void
    ) {
        sendUnreliableQueued(data, profile: profile, onComplete: onComplete)
    }

    func resetQueuedUnreliableSends(profile: MirageMedia.MirageMediaSendProfile) async {}

    func mirageQueuedUnreliableSendDiagnostics(
        profile: MirageMedia.MirageMediaSendProfile
    ) async -> MirageQueuedUnreliableSendDiagnostics? {
        nil
    }

    func close() async throws {}
}
#endif
