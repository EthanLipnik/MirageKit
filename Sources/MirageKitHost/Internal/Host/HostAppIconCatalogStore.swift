//
//  HostAppIconCatalogStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/16/26.
//

import CryptoKit
import Foundation
import MirageKit

#if os(macOS)
actor HostAppIconCatalogStore {
    struct IconPayload: Equatable, Sendable {
        let data: Data
        let signature: String
    }

    private struct CacheKey: Hashable {
        let bundleIdentifier: String
        let path: String
        let version: String
        let modificationToken: String
        let maxPixelSize: Int
        let heifQualityToken: Int
    }

    private let fileManager: FileManager
    private let entryLimit: Int
    private var payloadsByKey: [CacheKey: IconPayload] = [:]
    private var accessOrder: [CacheKey] = []

    init(
        fileManager: FileManager = .default,
        entryLimit: Int = 512
    ) {
        self.fileManager = fileManager
        self.entryLimit = max(1, entryLimit)
    }

    func payload(
        for app: MirageInstalledApp,
        maxPixelSize: Int,
        heifCompressionQuality: Double,
        loader: @Sendable () async -> Data?
    ) async -> IconPayload? {
        let key = cacheKey(
            for: app,
            maxPixelSize: maxPixelSize,
            heifCompressionQuality: heifCompressionQuality
        )

        if let cachedPayload = payloadsByKey[key] {
            markAccessed(key)
            return cachedPayload
        }

        guard let data = await loader(), !data.isEmpty else {
            return nil
        }

        let payload = IconPayload(
            data: data,
            signature: Self.sha256Hex(data)
        )
        payloadsByKey[key] = payload
        markAccessed(key)
        evictEntriesBeyondLimit()
        return payload
    }

    func removeAll() {
        payloadsByKey.removeAll(keepingCapacity: false)
        accessOrder.removeAll(keepingCapacity: false)
    }

    private func cacheKey(
        for app: MirageInstalledApp,
        maxPixelSize: Int,
        heifCompressionQuality: Double
    ) -> CacheKey {
        let normalizedPath = URL(fileURLWithPath: app.path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let modificationToken = appBundleModificationToken(path: normalizedPath)
        let qualityToken = Int((max(0.1, min(1.0, heifCompressionQuality)) * 1000).rounded())

        return CacheKey(
            bundleIdentifier: app.bundleIdentifier.lowercased(),
            path: normalizedPath,
            version: app.version ?? "",
            modificationToken: modificationToken,
            maxPixelSize: max(32, min(512, maxPixelSize)),
            heifQualityToken: qualityToken
        )
    }

    private func appBundleModificationToken(path: String) -> String {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let modificationDate = attributes[.modificationDate] as? Date
        else {
            return "missing"
        }

        return String(format: "%.6f", modificationDate.timeIntervalSinceReferenceDate)
    }

    private func markAccessed(_ key: CacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictEntriesBeyondLimit() {
        while payloadsByKey.count > entryLimit, let oldestKey = accessOrder.first {
            accessOrder.removeFirst()
            payloadsByKey.removeValue(forKey: oldestKey)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
