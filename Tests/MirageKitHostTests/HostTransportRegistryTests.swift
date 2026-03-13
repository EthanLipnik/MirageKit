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
import Network
import Testing

@Suite("Host Transport Registry")
struct HostTransportRegistryTests {
    @Test("Backlog pressure thresholds match export diagnostics expectations")
    func backlogPressureThresholds() {
        #expect(HostVideoTransportDiagnostics.backlogPressure(pendingPackets: 0, pendingBytes: 0) == .normal)
        #expect(
            HostVideoTransportDiagnostics.backlogPressure(
                pendingPackets: HostVideoTransportDiagnostics.backlogElevatedPacketCount,
                pendingBytes: 0
            ) == .elevated
        )
        #expect(
            HostVideoTransportDiagnostics.backlogPressure(
                pendingPackets: 0,
                pendingBytes: HostVideoTransportDiagnostics.backlogElevatedBytes
            ) == .elevated
        )
        #expect(
            HostVideoTransportDiagnostics.backlogPressure(
                pendingPackets: HostVideoTransportDiagnostics.backlogCriticalPacketCount,
                pendingBytes: 0
            ) == .critical
        )
        #expect(
            HostVideoTransportDiagnostics.backlogPressure(
                pendingPackets: 0,
                pendingBytes: HostVideoTransportDiagnostics.backlogCriticalBytes
            ) == .critical
        )
    }

    @Test("Send latency pressure thresholds surface stalled export sends")
    func sendLatencyPressureThresholds() {
        #expect(HostVideoTransportDiagnostics.sendLatencyPressure(elapsedMs: 0) == .normal)
        #expect(
            HostVideoTransportDiagnostics.sendLatencyPressure(
                elapsedMs: HostVideoTransportDiagnostics.sendLatencyElevatedMs
            ) == .elevated
        )
        #expect(
            HostVideoTransportDiagnostics.sendLatencyPressure(
                elapsedMs: HostVideoTransportDiagnostics.sendLatencyCriticalMs
            ) == .critical
        )
    }

    @Test("Missing video registration completes queued-byte release callback")
    func missingVideoRegistrationStillCompletes() {
        let registry = HostTransportRegistry()
        let didComplete = Locked(false)

        registry.sendVideo(streamID: 42, data: Data([0x01, 0x02])) { _ in
            didComplete.withLock { $0 = true }
        }

        #expect(didComplete.read { $0 })
    }

    @Test("Concurrent register/unregister keeps registry stable")
    func concurrentRegisterUnregisterIsStable() async {
        let registry = HostTransportRegistry()

        await withTaskGroup(of: Void.self) { group in
            for raw in 1 ... 128 {
                group.addTask {
                    let streamID = StreamID(raw)
                    let video = NWConnection(
                        to: .hostPort(host: .ipv4(.loopback), port: 9),
                        using: .udp
                    )
                    registry.registerVideoConnection(video, streamID: streamID)
                    _ = registry.unregisterVideoConnection(streamID: streamID)
                }
            }
        }

        for raw in 1 ... 128 {
            #expect(!registry.hasVideoConnection(streamID: StreamID(raw)))
        }
    }

    @Test("Unregister-all removes per-client media channels")
    func unregisterAllRemovesClientMediaChannels() {
        let registry = HostTransportRegistry()
        let clientID = UUID()

        let audio = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: 9),
            using: .udp
        )
        let quality = NWConnection(
            to: .hostPort(host: .ipv4(.loopback), port: 9),
            using: .udp
        )

        registry.registerAudioConnection(audio, clientID: clientID)
        registry.registerQualityConnection(quality, clientID: clientID)

        let removed = registry.unregisterAllConnections(clientID: clientID)
        #expect(removed.count == 2)
        #expect(!registry.hasAudioConnection(clientID: clientID))
    }
}

#endif
