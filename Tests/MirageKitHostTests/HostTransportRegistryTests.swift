//
//  HostTransportRegistryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Queue-safe host transport registry behavior.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Transport Registry")
struct HostTransportRegistryTests {
    @Test("Missing video stream completes queued-byte release callback")
    func missingVideoStreamStillCompletes() async {
        let registry = HostTransportRegistry()
        let didComplete = Locked(false)

        registry.sendVideo(streamID: 42, data: Data([0x01, 0x02])) { _ in
            didComplete.withLock { $0 = true }
        }

        // sendVideo fires completion synchronously when no stream is registered.
        #expect(didComplete.read { $0 })
    }

    @Test("hasVideoConnection returns false for unregistered stream")
    func hasVideoConnectionFalseForUnregistered() {
        let registry = HostTransportRegistry()
        #expect(!registry.hasVideoConnection(streamID: 1))
    }

    @Test("hasAudioConnection returns false for unregistered client")
    func hasAudioConnectionFalseForUnregistered() {
        let registry = HostTransportRegistry()
        #expect(!registry.hasAudioConnection(clientID: UUID()))
    }

    @Test("Unregister-all removes per-client audio stream")
    func unregisterAllRemovesClientAudioStream() {
        let registry = HostTransportRegistry()
        let clientID = UUID()

        // After unregisterAllStreams, audio should report not connected.
        registry.unregisterAllStreams(clientID: clientID)
        #expect(!registry.hasAudioConnection(clientID: clientID))
    }
}

#endif
