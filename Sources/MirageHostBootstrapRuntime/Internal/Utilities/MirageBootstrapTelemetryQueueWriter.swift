//
//  MirageBootstrapTelemetryQueueWriter.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Append-only JSONL queue writer used by daemon telemetry handoff.
//

import Foundation
import Loom

#if os(macOS)

actor MirageBootstrapTelemetryQueueWriter {
    private let appGroupIdentifier: String
    private let encoder: JSONEncoder

    init(appGroupIdentifier: String) {
        self.appGroupIdentifier = appGroupIdentifier
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
    }

    func append(_ event: LoomBootstrapTelemetryEventEnvelope) async {
        guard let queueURL = queueFileURL() else { return }

        let newLine: Data
        do {
            newLine = try encoder.encode(event)
        } catch {
            return
        }

        let existingLines = loadLines(from: queueURL)
        var lines = existingLines
        lines.append(newLine)
        enforceRetention(on: &lines)

        var output = Data()
        output.reserveCapacity(lines.reduce(0) { $0 + $1.count + 1 })
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }

        try? output.write(to: queueURL, options: .atomic)
    }

    private func queueFileURL() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }

        return containerURL.appendingPathComponent(LoomBootstrapTelemetryQueueConstants.fileName)
    }

    private func loadLines(from queueURL: URL) -> [Data] {
        guard let data = try? Data(contentsOf: queueURL), !data.isEmpty else {
            return []
        }

        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    private func enforceRetention(on lines: inout [Data]) {
        while lines.count > LoomBootstrapTelemetryQueueConstants.maxEntries {
            lines.removeFirst()
        }

        while queueSizeBytes(lines) > LoomBootstrapTelemetryQueueConstants.maxFileBytes,
              !lines.isEmpty {
            lines.removeFirst()
        }
    }

    private func queueSizeBytes(_ lines: [Data]) -> Int {
        lines.reduce(0) { $0 + $1.count + 1 }
    }
}

#endif
