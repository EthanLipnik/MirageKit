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
