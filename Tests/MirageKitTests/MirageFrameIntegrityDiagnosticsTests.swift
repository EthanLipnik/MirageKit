//
//  MirageFrameIntegrityDiagnosticsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

@testable import MirageKit
import Foundation
import Testing

@Suite("Frame Integrity Diagnostics")
struct MirageFrameIntegrityDiagnosticsTests {

    @Test("Explicit frame-integrity flag enables bounded CRC samples")
    func explicitIntegrityDiagnosticsCollectBoundedSamples() async throws {
        let lines = CapturedIntegrityLines()
        let diagnostics = MirageFrameIntegrityDiagnostics(
            configuration: MirageFrameIntegrityDiagnostics.Configuration(
                isEnabled: true,
                sampleLimit: 2,
                timeoutSeconds: 30,
                maxPendingSamples: 2
            ),
            startTime: 0,
            sink: { line in
                lines.append(line)
            }
        )

        diagnostics.recordPFrame(
            source: .encodedPFrame,
            streamID: 1,
            frameNumber: 10,
            frameBytes: Data([0, 1, 2, 3]),
            expectedBytes: 4,
            now: 1
        )
        diagnostics.recordPFrame(
            source: .reassembledPFrame,
            streamID: 1,
            frameNumber: 11,
            frameBytes: Data([4, 5, 6, 7]),
            expectedBytes: 4,
            now: 2
        )
        diagnostics.recordPFrame(
            source: .encodedPFrame,
            streamID: 1,
            frameNumber: 12,
            frameBytes: Data([8, 9, 10, 11]),
            expectedBytes: 4,
            now: 3
        )

        try await waitForIntegrityProcessing(diagnostics)

        let snapshot = diagnostics.snapshot()
        #expect(snapshot.acceptedSamples == 2)
        #expect(snapshot.processedSamples == 2)
        #expect(snapshot.droppedSamples == 1)
        #expect(lines.snapshot().count == 2)
        #expect(lines.snapshot().allSatisfy { $0.contains("CRC=") })
    }

    @Test("Disabled frame-integrity diagnostics drop hot-path work before copying")
    func disabledIntegrityDiagnosticsDoNotCollectSamples() {
        let lines = CapturedIntegrityLines()
        let diagnostics = MirageFrameIntegrityDiagnostics(
            configuration: MirageFrameIntegrityDiagnostics.Configuration(isEnabled: false),
            sink: { line in
                lines.append(line)
            }
        )

        diagnostics.recordPFrame(
            source: .encodedPFrame,
            streamID: 1,
            frameNumber: 10,
            frameBytes: Data([0, 1, 2, 3])
        )

        let snapshot = diagnostics.snapshot()
        #expect(snapshot.acceptedSamples == 0)
        #expect(snapshot.processedSamples == 0)
        #expect(snapshot.droppedSamples == 0)
        #expect(lines.snapshot().isEmpty)
    }

    private func waitForIntegrityProcessing(_ diagnostics: MirageFrameIntegrityDiagnostics) async throws {
        for _ in 0 ..< 20 {
            let snapshot = diagnostics.snapshot()
            if snapshot.processedSamples == snapshot.acceptedSamples, snapshot.pendingSamples == 0 {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

private final class CapturedIntegrityLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let result = lines
        lock.unlock()
        return result
    }
}
