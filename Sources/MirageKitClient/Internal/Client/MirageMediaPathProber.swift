//
//  MirageMediaPathProber.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/15/26.
//

import Foundation
import Network
import MirageKit

// MARK: - MediaPathProbeResult

struct MediaPathProbeResult: Sendable {
    let interfaceLabel: String
    let rttMs: Double
    let includePeerToPeer: Bool
    let interfaceType: NWInterface.InterfaceType?

    static func bestCandidate(from results: [MediaPathProbeResult]) -> MediaPathProbeResult? {
        results.min(by: { $0.rttMs < $1.rttMs })
    }

    static func shouldMigrate(
        from current: MediaPathProbeResult,
        to candidate: MediaPathProbeResult,
        threshold: Double = 0.30
    ) -> Bool {
        guard current.rttMs > 0 else { return false }
        let improvement = (current.rttMs - candidate.rttMs) / current.rttMs
        return improvement >= threshold
    }
}

// MARK: - MirageMediaPathProber

@MainActor
final class MirageMediaPathProber {
    private let host: NWEndpoint.Host
    private let port: UInt16
    private let enablePeerToPeer: Bool
    private let probeCount: Int
    private let probeTimeoutMs: Int
    private let monitorIntervalSeconds: Double
    private let migrationThreshold: Double
    private let consecutiveBetterRequired: Int

    private var monitorTask: Task<Void, Never>?
    private var consecutiveBetterCount: Int = 0
    private var pendingBetterCandidate: MediaPathProbeResult?

    var currentResult: MediaPathProbeResult?
    var onMigrationRecommended: ((MediaPathProbeResult) -> Void)?

    init(
        host: NWEndpoint.Host,
        port: UInt16,
        enablePeerToPeer: Bool,
        probeCount: Int = 3,
        probeTimeoutMs: Int = 500,
        monitorIntervalSeconds: Double = 30.0,
        migrationThreshold: Double = 0.30,
        consecutiveBetterRequired: Int = 2
    ) {
        self.host = host
        self.port = port
        self.enablePeerToPeer = enablePeerToPeer
        self.probeCount = probeCount
        self.probeTimeoutMs = probeTimeoutMs
        self.monitorIntervalSeconds = monitorIntervalSeconds
        self.migrationThreshold = migrationThreshold
        self.consecutiveBetterRequired = consecutiveBetterRequired
    }

    // MARK: - Public API

    func probeAllInterfaces() async -> [MediaPathProbeResult] {
        var candidates: [(label: String, interfaceType: NWInterface.InterfaceType?, includePeerToPeer: Bool)] = [
            ("ethernet", .wiredEthernet, false),
            ("wifi", .wifi, false),
        ]
        if enablePeerToPeer {
            candidates.append(("p2p", nil, true))
        }

        return await withTaskGroup(of: MediaPathProbeResult?.self) { group in
            for candidate in candidates {
                group.addTask { [host, port, probeCount, probeTimeoutMs] in
                    await Self.probeInterface(
                        host: host,
                        port: port,
                        interfaceLabel: candidate.label,
                        interfaceType: candidate.interfaceType,
                        includePeerToPeer: candidate.includePeerToPeer,
                        probeCount: probeCount,
                        probeTimeoutMs: probeTimeoutMs
                    )
                }
            }

            var results: [MediaPathProbeResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
    }

    func startMonitoring() {
        stopMonitoring()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.runProbeCycle()
                try? await Task.sleep(for: .seconds(self.monitorIntervalSeconds))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func triggerImmediateProbe() {
        Task { [weak self] in
            await self?.runProbeCycle()
        }
    }

    // MARK: - Probe Cycle

    private func runProbeCycle() async {
        let results = await probeAllInterfaces()
        guard let best = MediaPathProbeResult.bestCandidate(from: results) else { return }

        guard let current = currentResult else {
            currentResult = best
            consecutiveBetterCount = 0
            pendingBetterCandidate = nil
            MirageLogger.client("Probe initial result: \(best.interfaceLabel) rtt=\(String(format: "%.2f", best.rttMs))ms")
            return
        }

        if MediaPathProbeResult.shouldMigrate(from: current, to: best, threshold: migrationThreshold) {
            if let pending = pendingBetterCandidate, pending.interfaceLabel == best.interfaceLabel {
                consecutiveBetterCount += 1
            } else {
                pendingBetterCandidate = best
                consecutiveBetterCount = 1
            }

            MirageLogger.client(
                "Probe candidate \(best.interfaceLabel) rtt=\(String(format: "%.2f", best.rttMs))ms "
                + "vs current \(current.interfaceLabel) rtt=\(String(format: "%.2f", current.rttMs))ms "
                + "(\(consecutiveBetterCount)/\(consecutiveBetterRequired) consecutive)"
            )

            if consecutiveBetterCount >= consecutiveBetterRequired {
                currentResult = best
                consecutiveBetterCount = 0
                pendingBetterCandidate = nil
                onMigrationRecommended?(best)
            }
        } else {
            consecutiveBetterCount = 0
            pendingBetterCandidate = nil
            currentResult = best
        }
    }

    // MARK: - Single Interface Probe

    private nonisolated static func probeInterface(
        host: NWEndpoint.Host,
        port: UInt16,
        interfaceLabel: String,
        interfaceType: NWInterface.InterfaceType?,
        includePeerToPeer: Bool,
        probeCount: Int,
        probeTimeoutMs: Int
    ) async -> MediaPathProbeResult? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let params = NWParameters.udp
        params.includePeerToPeer = includePeerToPeer
        if let interfaceType {
            params.requiredInterfaceType = interfaceType
        }

        let endpoint = NWEndpoint.hostPort(host: host, port: endpointPort)
        let connection = NWConnection(to: endpoint, using: params)

        do {
            try await connectWithTimeout(
                connection: connection,
                timeoutMs: probeTimeoutMs
            )
        } catch {
            connection.cancel()
            return nil
        }

        var rttSamples: [Double] = []
        for seq in 0..<UInt32(probeCount) {
            if let rtt = await sendProbeAndMeasure(
                connection: connection,
                sequenceNumber: seq,
                timeoutMs: probeTimeoutMs
            ) {
                rttSamples.append(rtt)
            }
        }

        connection.cancel()

        guard !rttSamples.isEmpty else { return nil }

        let sorted = rttSamples.sorted()
        let median = sorted[sorted.count / 2]

        return MediaPathProbeResult(
            interfaceLabel: interfaceLabel,
            rttMs: median,
            includePeerToPeer: includePeerToPeer,
            interfaceType: interfaceType
        )
    }

    private nonisolated static func connectWithTimeout(
        connection: NWConnection,
        timeoutMs: Int
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox<Void>(continuation)

            let timeoutTask = Task {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                guard !Task.isCancelled else { return }
                box.resume(throwing: MirageError.timeout)
                connection.cancel()
            }

            connection.stateUpdateHandler = { [box, timeoutTask] state in
                switch state {
                case .ready:
                    timeoutTask.cancel()
                    box.resume()
                case let .failed(error):
                    timeoutTask.cancel()
                    box.resume(throwing: error)
                case .cancelled:
                    timeoutTask.cancel()
                    box.resume(throwing: MirageError.timeout)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private nonisolated static func sendProbeAndMeasure(
        connection: NWConnection,
        sequenceNumber: UInt32,
        timeoutMs: Int
    ) async -> Double? {
        let timestampNs = DispatchTime.now().uptimeNanoseconds
        let packet = MirageMediaPathProbePacket(
            sequenceNumber: sequenceNumber,
            timestampNs: UInt64(timestampNs)
        )
        let data = packet.serialize()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let box = ContinuationBox<Void>(continuation)
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error {
                            box.resume(throwing: error)
                        } else {
                            box.resume()
                        }
                    }
                )
            }
        } catch {
            return nil
        }

        return await receiveProbeReply(
            connection: connection,
            expectedSequence: sequenceNumber,
            sentTimestampNs: UInt64(timestampNs),
            timeoutMs: timeoutMs
        )
    }

    private nonisolated static func receiveProbeReply(
        connection: NWConnection,
        expectedSequence: UInt32,
        sentTimestampNs: UInt64,
        timeoutMs: Int
    ) async -> Double? {
        do {
            let replyData: Data = try await withCheckedThrowingContinuation { continuation in
                let box = ContinuationBox<Data>(continuation)

                let timeoutTask = Task {
                    try? await Task.sleep(for: .milliseconds(timeoutMs))
                    guard !Task.isCancelled else { return }
                    box.resume(throwing: MirageError.timeout)
                }

                connection.receive(
                    minimumIncompleteLength: MirageMediaPathProbePacket.packetSize,
                    maximumLength: MirageMediaPathProbePacket.packetSize
                ) { data, _, _, error in
                    timeoutTask.cancel()
                    if let error {
                        box.resume(throwing: error)
                    } else if let data {
                        box.resume(returning: data)
                    } else {
                        box.resume(throwing: MirageError.timeout)
                    }
                }
            }

            let reply = try MirageMediaPathProbePacket.deserialize(from: replyData)
            guard reply.sequenceNumber == expectedSequence else { return nil }
            guard reply.timestampNs == sentTimestampNs else { return nil }

            let nowNs = DispatchTime.now().uptimeNanoseconds
            let elapsedNs = nowNs - UInt64(sentTimestampNs)
            return Double(elapsedNs) / 1_000_000.0
        } catch {
            return nil
        }
    }
}
