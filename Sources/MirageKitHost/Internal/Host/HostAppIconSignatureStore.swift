//
//  HostAppIconSignatureStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//

import Foundation

#if os(macOS)
actor HostAppIconSignatureStore {
    private struct ClientEntry: Codable {
        var updatedAt: Date
        var signaturesByBundleIdentifier: [String: String]
    }

    private struct PersistedState: Codable {
        var clientsByID: [String: ClientEntry]
    }

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileURL: URL
    private let retentionInterval: TimeInterval
    private var state: PersistedState

    init(
        fileURL: URL? = nil,
        retentionInterval: TimeInterval = 60 * 60 * 24 * 90
    ) {
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        self.retentionInterval = retentionInterval

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let storeDirectory = appSupportDirectory
                .appendingPathComponent("MirageKit", isDirectory: true)
                .appendingPathComponent("HostIconSignatures", isDirectory: true)
            self.fileURL = storeDirectory.appendingPathComponent("state.json", isDirectory: false)
        }

        let loadedState: PersistedState
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? decoder.decode(PersistedState.self, from: data) {
            loadedState = decoded
        } else {
            loadedState = PersistedState(clientsByID: [:])
        }

        let prunedState = Self.prunedState(
            loadedState,
            now: Date(),
            retentionInterval: retentionInterval
        )
        state = prunedState
        if prunedState.clientsByID.count != loadedState.clientsByID.count {
            Self.persistStateSnapshot(
                prunedState,
                to: self.fileURL,
                fileManager: fileManager,
                encoder: encoder
            )
        }
    }

    func signatures(for clientID: UUID) -> [String: String] {
        pruneExpiredEntries(now: Date())
        let key = clientID.uuidString.lowercased()
        let now = Date()
        var entry = state.clientsByID[key] ?? ClientEntry(updatedAt: now, signaturesByBundleIdentifier: [:])
        entry.updatedAt = now
        state.clientsByID[key] = entry
        persistState()
        return entry.signaturesByBundleIdentifier
    }

    func mergeSignatures(_ signaturesByBundleIdentifier: [String: String], for clientID: UUID) {
        pruneExpiredEntries(now: Date())
        let key = clientID.uuidString.lowercased()
        let now = Date()
        var entry = state.clientsByID[key] ?? ClientEntry(updatedAt: now, signaturesByBundleIdentifier: [:])

        for (bundleIdentifier, signature) in signaturesByBundleIdentifier {
            let normalizedBundleIdentifier = bundleIdentifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedBundleIdentifier.isEmpty else { continue }
            let normalizedSignature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedSignature.isEmpty else { continue }
            entry.signaturesByBundleIdentifier[normalizedBundleIdentifier] = normalizedSignature
        }

        entry.updatedAt = now
        state.clientsByID[key] = entry
        persistState()
    }

    func touch(clientID: UUID) {
        pruneExpiredEntries(now: Date())
        let key = clientID.uuidString.lowercased()
        let now = Date()
        var entry = state.clientsByID[key] ?? ClientEntry(updatedAt: now, signaturesByBundleIdentifier: [:])
        entry.updatedAt = now
        state.clientsByID[key] = entry
        persistState()
    }

    @discardableResult
    func pruneExpiredEntries(now: Date = Date()) -> Bool {
        let cutoffDate = now.addingTimeInterval(-retentionInterval)
        let staleClientIDs = state.clientsByID
            .filter { $0.value.updatedAt < cutoffDate }
            .map(\.key)

        guard !staleClientIDs.isEmpty else {
            return false
        }

        for staleClientID in staleClientIDs {
            state.clientsByID.removeValue(forKey: staleClientID)
        }

        persistState()

        return true
    }

    private func persistState() {
        Self.persistStateSnapshot(state, to: fileURL, fileManager: fileManager, encoder: encoder)
    }

    private nonisolated static func prunedState(
        _ state: PersistedState,
        now: Date,
        retentionInterval: TimeInterval
    ) -> PersistedState {
        let cutoffDate = now.addingTimeInterval(-retentionInterval)
        let activeClients = state.clientsByID.filter { $0.value.updatedAt >= cutoffDate }
        return PersistedState(clientsByID: activeClients)
    }

    private nonisolated static func persistStateSnapshot(
        _ state: PersistedState,
        to fileURL: URL,
        fileManager: FileManager,
        encoder: JSONEncoder
    ) {
        guard let encoded = try? encoder.encode(state) else { return }

        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}
#endif
