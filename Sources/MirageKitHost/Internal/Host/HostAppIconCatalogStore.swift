//
//  HostAppIconCatalogStore.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/16/26.
//

import Foundation
import MirageKit

#if os(macOS)
/// Actor-isolated in-memory cache for encoded app icon payloads.
actor HostAppIconCatalogStore {
    /// Encoded icon bytes ready for transport to a client.
    struct IconPayload: Equatable {
        /// HEIF-encoded image data.
        let data: Data
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

    /// Creates an icon cache with a bounded number of entries.
    init(
        fileManager: FileManager = .default,
        entryLimit: Int = 512
    ) {
        self.fileManager = fileManager
        self.entryLimit = max(1, entryLimit)
    }

    /// Returns a cached icon payload or loads and stores it when missing.
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

        let payload = IconPayload(data: data)
        payloadsByKey[key] = payload
        markAccessed(key)
        evictEntriesBeyondLimit()
        return payload
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
        let modificationToken = if let attributes = try? fileManager.attributesOfItem(atPath: normalizedPath),
                                   let modificationDate = attributes[.modificationDate] as? Date {
            String(format: "%.6f", modificationDate.timeIntervalSinceReferenceDate)
        } else {
            "missing"
        }
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
}
#endif
