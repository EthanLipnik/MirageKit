//
//  MirageFrameIntegrityDiagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation

package final class MirageFrameIntegrityDiagnostics: @unchecked Sendable {
    package enum SampleSource: String, Equatable {
        case encodedPFrame = "Encoded P-frame"
        case reassembledPFrame = "Reassembled P-frame"
    }

    package struct Configuration: Equatable {
        package let isEnabled: Bool
        package let sampleLimit: Int
        package let timeoutSeconds: TimeInterval
        package let maxPendingSamples: Int

        package init(
            isEnabled: Bool,
            sampleLimit: Int = 120,
            timeoutSeconds: TimeInterval = 30,
            maxPendingSamples: Int = 16
        ) {
            self.isEnabled = isEnabled
            self.sampleLimit = max(0, sampleLimit)
            self.timeoutSeconds = max(0, timeoutSeconds)
            self.maxPendingSamples = max(1, maxPendingSamples)
        }

        package static func from(environment: [String: String]) -> Configuration {
            let enabled = MirageEnvironmentValue.isTruthy(
                environment["MIRAGE_FRAME_INTEGRITY_DIAGNOSTICS"]
            )
            let sampleLimit = environment["MIRAGE_FRAME_INTEGRITY_SAMPLE_LIMIT"]
                .flatMap(Int.init) ?? 120
            let timeoutSeconds = environment["MIRAGE_FRAME_INTEGRITY_TIMEOUT_SECONDS"]
                .flatMap(TimeInterval.init) ?? 30
            let maxPendingSamples = environment["MIRAGE_FRAME_INTEGRITY_PENDING_LIMIT"]
                .flatMap(Int.init) ?? 16
            return Configuration(
                isEnabled: enabled,
                sampleLimit: sampleLimit,
                timeoutSeconds: timeoutSeconds,
                maxPendingSamples: maxPendingSamples
            )
        }

        package static let processEnvironment: Configuration = from(environment: ProcessInfo.processInfo.environment)
    }

    private struct Sample {
        let source: SampleSource
        let streamID: StreamID
        let frameNumber: UInt32
        let frameBytes: Data
        let expectedBytes: Int?
    }

    private struct State {
        var pendingSamples: [Sample] = []
        var reservedSamples = 0
        var acceptedSamples: UInt64 = 0
        var processedSamples: UInt64 = 0
        var droppedSamples: UInt64 = 0
        var isWorkerScheduled = false
    }

    package static let shared = MirageFrameIntegrityDiagnostics()

    private let configuration: Configuration
    private let startTime: CFAbsoluteTime
    private let queue = DispatchQueue(label: "com.mirage.frame-integrity-diagnostics", qos: .utility)
    private let state = MirageDiagnostics.MirageDiagnosticsLocked(State())
    private let sink: @Sendable (String) -> Void

    package init(
        configuration: Configuration = .processEnvironment,
        startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
        sink: @escaping @Sendable (String) -> Void = { message in
            MirageLogger.log(.frameAssembly, message)
        }
    ) {
        self.configuration = configuration
        self.startTime = startTime
        self.sink = sink
    }

    package func recordPFrame(
        source: SampleSource,
        streamID: StreamID,
        frameNumber: UInt32,
        frameBytes: Data,
        expectedBytes: Int? = nil,
        now: CFAbsoluteTime? = nil
    ) {
        guard configuration.isEnabled, configuration.sampleLimit > 0 else { return }
        let resolvedNow = now ?? CFAbsoluteTimeGetCurrent()
        guard resolvedNow - startTime <= configuration.timeoutSeconds else { return }

        let shouldAccept = state.withLock { state -> Bool in
            guard state.acceptedSamples < UInt64(configuration.sampleLimit),
                  state.reservedSamples < configuration.maxPendingSamples else {
                state.droppedSamples &+= 1
                return false
            }

            state.acceptedSamples &+= 1
            state.reservedSamples += 1
            return true
        }
        guard shouldAccept else { return }

        let copiedFrame = frameBytes.withUnsafeBytes { rawBuffer in
            Data(rawBuffer)
        }
        let sample = Sample(
            source: source,
            streamID: streamID,
            frameNumber: frameNumber,
            frameBytes: copiedFrame,
            expectedBytes: expectedBytes
        )

        let shouldSchedule = state.withLock { state -> Bool in
            state.pendingSamples.append(sample)
            if state.isWorkerScheduled { return false }
            state.isWorkerScheduled = true
            return true
        }

        if shouldSchedule {
            queue.async { [weak self] in
                self?.drainSamples()
            }
        }
    }

    package static func diagnosticLine(
        source: SampleSource,
        streamID: StreamID,
        frameNumber: UInt32,
        frameBytes: Data,
        expectedBytes: Int? = nil
    ) -> String {
        let crc = MirageWire.CRC32.calculate(frameBytes)
        let header = frameBytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let expectedText = expectedBytes.map { ", expected=\($0)" } ?? ""
        return "\(source.rawValue) CRC=\(String(format: "%08X", crc)), stream=\(streamID), frame=\(frameNumber), size=\(frameBytes.count)\(expectedText), header: \(header)"
    }

    private func drainSamples() {
        while true {
            let sample = state.withLock { state -> Sample? in
                guard !state.pendingSamples.isEmpty else {
                    state.isWorkerScheduled = false
                    return nil
                }
                state.reservedSamples = max(0, state.reservedSamples - 1)
                return state.pendingSamples.removeFirst()
            }

            guard let sample else { return }
            let line = Self.diagnosticLine(
                source: sample.source,
                streamID: sample.streamID,
                frameNumber: sample.frameNumber,
                frameBytes: sample.frameBytes,
                expectedBytes: sample.expectedBytes
            )
            sink(line)
            state.withLock { state in
                state.processedSamples &+= 1
            }
        }
    }
}
