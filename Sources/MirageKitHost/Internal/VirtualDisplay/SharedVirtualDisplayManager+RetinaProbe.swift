//
//  SharedVirtualDisplayManager+RetinaProbe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/24/26.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

// MARK: - Retina Probe Types

struct RetinaProbeEntry: Sendable, Codable, Equatable {
    let pixelWidth: Int
    let pixelHeight: Int
    let worksAt2x: Bool
}

struct RetinaProbeCache: Sendable, Codable {
    let osBuild: String
    let probedAt: Date
    let entries: [RetinaProbeEntry]
}

// MARK: - Probe Candidate Generation

extension SharedVirtualDisplayManager {

    /// Aspect ratios to probe, as (width, height) integer ratios.
    private static let probeAspectRatios: [(Int, Int)] = [
        (4, 3),    // iPad
        (3, 2),    // Classic Mac
        (16, 10),  // MacBook
        (16, 9),   // External 4K/1080p
        (5, 4),    // Legacy
        (5, 3),    // iPad mini-ish
        (3, 4),    // Portrait iPad
        (2, 3),    // Portrait 3:2
    ]

    /// Generate probe candidates: logical resolutions across multiple aspect ratios and sizes.
    /// Each candidate is a pixel resolution (logical × 2).
    static func generateProbeCandidates() -> [CGSize] {
        var seen = Set<String>()
        var candidates: [CGSize] = []

        for (aw, ah) in probeAspectRatios {
            // Logical widths from 960 to 2560, stepping by 64
            var logicalWidth = 960
            while logicalWidth <= 2560 {
                let logicalHeight = (logicalWidth * ah) / aw
                // Pixel = logical × 2, aligned to even
                let px = alignedEven(logicalWidth * 2)
                let py = alignedEven(logicalHeight * 2)

                let key = "\(px)x\(py)"
                if seen.insert(key).inserted, px >= 1920, py >= 1440 {
                    candidates.append(CGSize(width: CGFloat(px), height: CGFloat(py)))
                }
                logicalWidth += 64
                if logicalWidth <= 2560 { continue }
                break
            }
        }

        // Sort by total pixel count (smallest first) for efficient probing
        candidates.sort { ($0.width * $0.height) < ($1.width * $1.height) }
        return candidates
    }

    private static func alignedEven(_ value: Int) -> Int {
        let even = value - (value % 2)
        return max(even, 2)
    }
}

// MARK: - Probe Execution

extension SharedVirtualDisplayManager {

    /// Probe which pixel resolutions support 2x HiDPI on virtual displays.
    /// Creates a single virtual display and iterates resolutions via updateDisplayResolution.
    static func probeRetinaResolutions(
        candidates: [CGSize],
        colorSpace: MirageColorSpace = .displayP3,
        refreshRate: Double = 60.0
    ) -> [RetinaProbeEntry] {
        guard !candidates.isEmpty else { return [] }

        // Start with the first candidate to create the initial display
        let first = candidates[0]

        guard let context = CGVirtualDisplayBridge.createVirtualDisplay(
            name: "Mirage Retina Probe",
            width: Int(first.width),
            height: Int(first.height),
            refreshRate: refreshRate,
            hiDPI: true,
            colorSpace: colorSpace
        ) else {
            MirageLogger.error(.host, "Retina probe: failed to create initial virtual display")
            return []
        }

        let initialScale = context.scaleFactor
        var results: [RetinaProbeEntry] = []

        // Record first candidate
        results.append(RetinaProbeEntry(
            pixelWidth: Int(first.width),
            pixelHeight: Int(first.height),
            worksAt2x: initialScale >= 1.5
        ))

        // Test remaining candidates by updating the display resolution
        for candidate in candidates.dropFirst() {
            let success = CGVirtualDisplayBridge.updateDisplayResolution(
                display: context.display,
                width: Int(candidate.width),
                height: Int(candidate.height),
                refreshRate: refreshRate,
                hiDPI: true,
                colorSpace: colorSpace,
                isFallbackProbe: true
            )

            if success {
                // Verify actual scale via mode query
                let modes = CGVirtualDisplayBridge.currentDisplayModeSizes(context.displayID)
                let actualScale: CGFloat
                if let modes, modes.logical.width > 0 {
                    actualScale = modes.pixel.width / modes.logical.width
                } else {
                    actualScale = 1.0
                }
                results.append(RetinaProbeEntry(
                    pixelWidth: Int(candidate.width),
                    pixelHeight: Int(candidate.height),
                    worksAt2x: actualScale >= 1.5
                ))
            } else {
                results.append(RetinaProbeEntry(
                    pixelWidth: Int(candidate.width),
                    pixelHeight: Int(candidate.height),
                    worksAt2x: false
                ))
            }
        }

        // Destroy the probe display
        let invalidateSelector = NSSelectorFromString("invalidate")
        if (context.display as AnyObject).responds(to: invalidateSelector) {
            _ = (context.display as AnyObject).perform(invalidateSelector)
        }

        return results
    }
}

// MARK: - Probe Cache Persistence

extension SharedVirtualDisplayManager {

    static let retinaProbeCacheDefaultsKey = "Mirage.VirtualDisplay.RetinaProbeCache.v1"
    static let retinaProbeCacheTTL: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    private static func currentOSBuild() -> String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var build = [CChar](repeating: 0, count: size)
        sysctlbyname("kern.osversion", &build, &size, nil, 0)
        return String(decoding: build.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
    }

    static func loadRetinaProbeCacheIfValid(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> RetinaProbeCache? {
        guard let data = defaults.data(forKey: retinaProbeCacheDefaultsKey),
              let cache = try? JSONDecoder().decode(RetinaProbeCache.self, from: data) else {
            return nil
        }

        // Invalidate if OS build changed or cache expired
        let osBuild = currentOSBuild()
        guard cache.osBuild == osBuild else {
            MirageLogger.host("Retina probe cache invalidated: OS build changed (\(cache.osBuild) → \(osBuild))")
            return nil
        }
        guard now.timeIntervalSince(cache.probedAt) < retinaProbeCacheTTL else {
            MirageLogger.host("Retina probe cache expired (\(Int(now.timeIntervalSince(cache.probedAt) / 86400))d old)")
            return nil
        }

        return cache
    }

    static func persistRetinaProbeCache(
        _ entries: [RetinaProbeEntry],
        defaults: UserDefaults = .standard
    ) {
        let cache = RetinaProbeCache(
            osBuild: currentOSBuild(),
            probedAt: Date(),
            entries: entries
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: retinaProbeCacheDefaultsKey)
    }
}

// MARK: - Probe Query

extension SharedVirtualDisplayManager {

    /// Find the smallest probed-good 2x resolution that fits the given pixel dimensions.
    static func closestProbedRetinaResolution(
        neededPixelWidth: Int,
        neededPixelHeight: Int,
        cache: RetinaProbeCache
    ) -> CGSize? {
        let good = cache.entries
            .filter { $0.worksAt2x && $0.pixelWidth >= neededPixelWidth && $0.pixelHeight >= neededPixelHeight }
            .sorted { ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight) }

        guard let best = good.first else { return nil }
        return CGSize(width: CGFloat(best.pixelWidth), height: CGFloat(best.pixelHeight))
    }

    /// Record a runtime-discovered resolution outcome into the probe cache.
    static func appendRuntimeProbeResult(
        pixelWidth: Int,
        pixelHeight: Int,
        worksAt2x: Bool,
        defaults: UserDefaults = .standard
    ) {
        var cache = loadRetinaProbeCacheIfValid(defaults: defaults) ?? RetinaProbeCache(
            osBuild: currentOSBuild(),
            probedAt: Date(),
            entries: []
        )

        // Don't duplicate
        let key = "\(pixelWidth)x\(pixelHeight)"
        if cache.entries.contains(where: { "\($0.pixelWidth)x\($0.pixelHeight)" == key }) {
            return
        }

        var entries = cache.entries
        entries.append(RetinaProbeEntry(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            worksAt2x: worksAt2x
        ))

        cache = RetinaProbeCache(
            osBuild: cache.osBuild,
            probedAt: cache.probedAt,
            entries: entries
        )

        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: retinaProbeCacheDefaultsKey)

        MirageLogger.host(
            "Retina probe cache updated: \(pixelWidth)x\(pixelHeight) \(worksAt2x ? "✓ 2x" : "✗ 1x") (runtime discovery)"
        )
    }
}
#endif
