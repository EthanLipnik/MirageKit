//
//  MirageBootstrapControlCommandQueue.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//

import Foundation
import Loom

#if os(macOS)

public enum MirageBootstrapControlCommandQueueConstants {
    public static let fileName = "mirage-bootstrap-control-commands.jsonl"
    public static let maxEntries = 50
    public static let maxFileBytes = 256 * 1024
}

public struct MirageBootstrapControlCommandEnvelope: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let identifier: String
    public let body: Data?
    public let peerKeyID: String
    public let peerPublicKey: Data
    public let peerEndpoint: String
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        identifier: String,
        body: Data?,
        peerKeyID: String,
        peerPublicKey: Data,
        peerEndpoint: String,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.identifier = identifier
        self.body = body
        self.peerKeyID = peerKeyID
        self.peerPublicKey = peerPublicKey
        self.peerEndpoint = peerEndpoint
        self.receivedAt = receivedAt
    }

    public var authenticatedPeer: LoomBootstrapControlPeer {
        LoomBootstrapControlPeer(
            keyID: peerKeyID,
            publicKey: peerPublicKey,
            endpoint: peerEndpoint
        )
    }
}

public actor MirageBootstrapControlCommandQueueWriter {
    private let appGroupIdentifier: String
    private let encoder: JSONEncoder

    public init(appGroupIdentifier: String) {
        self.appGroupIdentifier = appGroupIdentifier
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
    }

    public func append(_ command: MirageBootstrapControlCommandEnvelope) async throws {
        guard let queueURL = Self.queueFileURL(appGroupIdentifier: appGroupIdentifier) else {
            return
        }

        let newLine = try encoder.encode(command)
        let existingLines = Self.loadLines(from: queueURL)
        var lines = existingLines
        lines.append(newLine)
        Self.enforceRetention(on: &lines)

        var output = Data()
        output.reserveCapacity(Self.queueSizeBytes(lines))
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }

        try output.write(to: queueURL, options: .atomic)
    }

    public static func queueFileURL(appGroupIdentifier: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return containerURL.appendingPathComponent(MirageBootstrapControlCommandQueueConstants.fileName)
    }

    private static func loadLines(from queueURL: URL) -> [Data] {
        guard let data = try? Data(contentsOf: queueURL), !data.isEmpty else {
            return []
        }

        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    private static func enforceRetention(on lines: inout [Data]) {
        while lines.count > MirageBootstrapControlCommandQueueConstants.maxEntries {
            lines.removeFirst()
        }

        while queueSizeBytes(lines) > MirageBootstrapControlCommandQueueConstants.maxFileBytes,
              !lines.isEmpty {
            lines.removeFirst()
        }
    }

    private static func queueSizeBytes(_ lines: [Data]) -> Int {
        lines.reduce(0) { $0 + $1.count + 1 }
    }
}

#endif
