//
//  ClientVideoPacketIngressProcessorTestSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

@testable import MirageKitClient
import Foundation
import MirageCore
import MirageDiagnostics
import MirageWire
@testable import MirageKit

@MainActor
func waitForProcessor(
    service: MirageClientService,
    streamID: StreamID
) async -> ClientVideoPacketIngressProcessor? {
    let deadline = CFAbsoluteTimeGetCurrent() + 3.0
    while CFAbsoluteTimeGetCurrent() < deadline {
        if let processor = service.videoPacketIngressProcessors[streamID] {
            return processor
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

func waitForProcessedPackets(
    processor: ClientVideoPacketIngressProcessor,
    count: UInt64
) async -> Bool {
    let deadline = CFAbsoluteTimeGetCurrent() + 3.0
    while CFAbsoluteTimeGetCurrent() < deadline {
        if processor.snapshot().processedPacketCount >= count {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@MainActor
func waitForIngressSnapshot(
    service: MirageClientService,
    streamID: StreamID,
    count: UInt64
) async -> MirageClientVideoIngressMetricsSnapshot? {
    let deadline = CFAbsoluteTimeGetCurrent() + 3.0
    while CFAbsoluteTimeGetCurrent() < deadline {
        if let snapshot = service.videoIngressTelemetryStore.snapshot(for: streamID),
           snapshot.processedPacketCount >= count {
            return snapshot
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return service.videoIngressTelemetryStore.snapshot(for: streamID)
}

func makeVideoPacket(
    streamID: StreamID,
    frameNumber: UInt32,
    flags: MirageWire.FrameFlags,
    fecBlockSize: UInt8 = 0
) -> Data {
    MirageWire.FrameHeader(
        flags: flags,
        streamID: streamID,
        sequenceNumber: frameNumber,
        timestamp: UInt64(frameNumber),
        frameNumber: frameNumber,
        fragmentIndex: 0,
        fragmentCount: 1,
        fecBlockSize: fecBlockSize,
        payloadLength: 0,
        frameByteCount: 0,
        checksum: 0
    ).serialize()
}

struct ReceivedPacket: Sendable, Equatable {
    let data: Data
    let streamID: StreamID
}

final class PacketProcessingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBlocked = false
    private var started: [ReceivedPacket] = []
    private var received: [ReceivedPacket] = []

    func block() {
        lock.lock()
        isBlocked = true
        lock.unlock()
    }

    func unblock() {
        lock.lock()
        isBlocked = false
        lock.unlock()
    }

    func record(_ data: Data, streamID: StreamID) {
        lock.lock()
        started.append(ReceivedPacket(data: data, streamID: streamID))
        lock.unlock()

        while true {
            lock.lock()
            let blocked = isBlocked
            lock.unlock()
            if !blocked { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        lock.lock()
        received.append(ReceivedPacket(data: data, streamID: streamID))
        lock.unlock()
    }

    func payloads(target: Int, timeoutSeconds: TimeInterval) async -> [ReceivedPacket]? {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = snapshot()
            if snapshot.count >= target { return Array(snapshot.prefix(target)) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func payloads(timeoutSeconds: TimeInterval) async -> [ReceivedPacket] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = snapshot()
            if !snapshot.isEmpty { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot()
    }

    func payloads(containing data: Data, timeoutSeconds: TimeInterval) async -> [ReceivedPacket] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = snapshot()
            if snapshot.contains(where: { $0.data == data }) { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot()
    }

    func startedPayloads(containing data: Data, timeoutSeconds: TimeInterval) async -> [ReceivedPacket] {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutSeconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            let snapshot = startedSnapshot()
            if snapshot.contains(where: { $0.data == data }) { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return startedSnapshot()
    }

    private func snapshot() -> [ReceivedPacket] {
        lock.lock()
        let snapshot = received
        lock.unlock()
        return snapshot
    }

    private func startedSnapshot() -> [ReceivedPacket] {
        lock.lock()
        let snapshot = started
        lock.unlock()
        return snapshot
    }
}
