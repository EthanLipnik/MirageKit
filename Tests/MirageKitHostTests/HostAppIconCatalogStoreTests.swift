//
//  HostAppIconCatalogStoreTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/16/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Host app icon catalog store")
struct HostAppIconCatalogStoreTests {
    @Test("Store reuses payloads for stable app identity")
    func storeReusesPayloadsForStableAppIdentity() async throws {
        let temporaryDirectory = try makeTemporaryAppBundle()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let app = MirageInstalledApp(
            bundleIdentifier: "com.example.TestApp",
            name: "TestApp",
            path: temporaryDirectory.path,
            version: "1.0"
        )
        let store = HostAppIconCatalogStore()
        let loaderCalls = LockedCounter()

        let first = await store.payload(
            for: app,
            maxPixelSize: 128,
            heifCompressionQuality: 0.72
        ) {
            loaderCalls.increment()
            return Data([0x01, 0x02, 0x03])
        }
        let second = await store.payload(
            for: app,
            maxPixelSize: 128,
            heifCompressionQuality: 0.72
        ) {
            loaderCalls.increment()
            return Data([0x04, 0x05, 0x06])
        }

        #expect(loaderCalls.value == 1)
        #expect(first == second)
    }

    @Test("Store invalidates payloads when app bundle changes")
    func storeInvalidatesPayloadsWhenAppBundleChanges() async throws {
        let temporaryDirectory = try makeTemporaryAppBundle()
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let app = MirageInstalledApp(
            bundleIdentifier: "com.example.TestApp",
            name: "TestApp",
            path: temporaryDirectory.path,
            version: "1.0"
        )
        let store = HostAppIconCatalogStore()
        let loaderCalls = LockedCounter()

        let first = await store.payload(
            for: app,
            maxPixelSize: 128,
            heifCompressionQuality: 0.72
        ) {
            loaderCalls.increment()
            return Data([0x01, 0x02, 0x03])
        }

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: temporaryDirectory.path
        )

        let second = await store.payload(
            for: app,
            maxPixelSize: 128,
            heifCompressionQuality: 0.72
        ) {
            loaderCalls.increment()
            return Data([0x04, 0x05, 0x06])
        }

        #expect(loaderCalls.value == 2)
        #expect(first != second)
    }

    private func makeTemporaryAppBundle() throws -> URL {
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HostAppIconCatalogStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("app")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        return temporaryDirectory
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
#endif
