//
//  MirageCodecBenchmarkStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/2/26.
//
//  Local storage for codec benchmark results.
//

import Foundation

package struct MirageCodecBenchmarkStore {
    package struct Record: Codable, Equatable {
        package let version: Int
        package let benchmarkWidth: Int
        package let benchmarkHeight: Int
        package let benchmarkFrameRate: Int
        package let hostEncodeMs: Double?
        package let clientDecodeMs: Double?
        package let measuredAt: Date

        package init(
            version: Int,
            benchmarkWidth: Int,
            benchmarkHeight: Int,
            benchmarkFrameRate: Int,
            hostEncodeMs: Double?,
            clientDecodeMs: Double?,
            measuredAt: Date
        ) {
            self.version = version
            self.benchmarkWidth = benchmarkWidth
            self.benchmarkHeight = benchmarkHeight
            self.benchmarkFrameRate = benchmarkFrameRate
            self.hostEncodeMs = hostEncodeMs
            self.clientDecodeMs = clientDecodeMs
            self.measuredAt = measuredAt
        }
    }

    package static let currentVersion = 1

    private let fileURL: URL

    package init(filename: String = "MirageCodecBenchmark.json") {
        fileURL = URL.cachesDirectory.appending(path: filename)
    }

    package func load() -> Record? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    package func save(_ record: Record) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = fileURL
            try? mutableURL.setResourceValues(values)
        } catch {
            return
        }
    }
}
