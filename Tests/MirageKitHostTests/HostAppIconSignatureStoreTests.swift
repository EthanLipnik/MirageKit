//
//  HostAppIconSignatureStoreTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//

@testable import MirageKitHost
import Foundation
import Testing

@Suite("Host app icon signature store")
struct HostAppIconSignatureStoreTests {
    @Test("Store persists merged signatures across reloads")
    func storePersistsMergedSignaturesAcrossReloads() async {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HostAppIconSignatureStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("state.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000777")!

        let store = HostAppIconSignatureStore(fileURL: fileURL)
        let initialSignatures = await store.signatures(for: clientID)
        #expect(initialSignatures.isEmpty)

        await store.mergeSignatures([
            "com.apple.mail": "sig-mail-v1",
            "com.apple.finder": "sig-finder-v1",
        ], for: clientID)

        let persisted = await store.signatures(for: clientID)
        #expect(persisted["com.apple.mail"] == "sig-mail-v1")
        #expect(persisted["com.apple.finder"] == "sig-finder-v1")

        let reloaded = HostAppIconSignatureStore(fileURL: fileURL)
        let reloadedSignatures = await reloaded.signatures(for: clientID)
        #expect(reloadedSignatures["com.apple.mail"] == "sig-mail-v1")
        #expect(reloadedSignatures["com.apple.finder"] == "sig-finder-v1")
    }

    @Test("Store prunes stale clients with retention policy")
    func storePrunesStaleClients() async {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HostAppIconSignatureStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("state.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000888")!

        let store = HostAppIconSignatureStore(fileURL: fileURL, retentionInterval: 1)
        await store.mergeSignatures([
            "com.apple.mail": "sig-mail-v1",
        ], for: clientID)

        let pruned = await store.pruneExpiredEntries(now: Date().addingTimeInterval(2))
        #expect(pruned)

        let reloaded = HostAppIconSignatureStore(fileURL: fileURL, retentionInterval: 1)
        let prunedSignatures = await reloaded.signatures(for: clientID)
        #expect(prunedSignatures.isEmpty)
    }
}
