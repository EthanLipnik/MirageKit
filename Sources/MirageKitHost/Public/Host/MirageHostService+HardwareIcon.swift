//
//  MirageHostService+HardwareIcon.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)

extension MirageHostService {
    private struct CoreTypesHostIconEntry {
        let lowercasedName: String
        let originalName: String
        let size: Int
    }

    /// Resolves the best CoreTypes hardware icon for a host model and optional color code.
    static func hardwareIconName(
        for modelIdentifier: String?,
        hardwareColorCode: Int?
    ) -> String? {
        guard let normalizedModel = normalizeModelIdentifier(modelIdentifier) else {
            return nil
        }
        guard let coreTypesPath = coreTypesBundlePath() else {
            return nil
        }

        var iconEntries: [CoreTypesHostIconEntry] = []
        var plistPaths: [String] = []
        let fileManager = FileManager.default

        if let enumerator = fileManager.enumerator(atPath: coreTypesPath) {
            for case let relativePath as String in enumerator {
                let lowercasedPath = relativePath.lowercased()

                if lowercasedPath.hasSuffix(".icns") {
                    let fullPath = coreTypesPath + "/" + relativePath
                    let attributes = try? fileManager.attributesOfItem(atPath: fullPath)
                    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                    let originalName = (relativePath as NSString).lastPathComponent
                    iconEntries.append(
                        CoreTypesHostIconEntry(
                            lowercasedName: originalName.lowercased(),
                            originalName: originalName,
                            size: size
                        )
                    )
                    continue
                }

                if lowercasedPath.hasSuffix("/info.plist") {
                    plistPaths.append(coreTypesPath + "/" + relativePath)
                }
            }
        }

        guard !iconEntries.isEmpty else {
            return nil
        }

        let metadata = parseCoreTypesMetadata(plistPaths: plistPaths)
        let preferredModelTag = hardwareColorCode.map { "\(normalizedModel)@ecolor=\($0)" }
        let preferredTypes = preferredModelTag.flatMap { metadata.modelTagToTypeIdentifiers[$0] } ?? []
        let mappedTypes = metadata.modelToTypeIdentifiers[normalizedModel] ?? []
        let resolvedPreferredColorHints = preferredColorHints(from: preferredTypes)
        let expandedPreferredTypes = preferredTypes.isEmpty
            ? Set<String>()
            : expandTypeIdentifiers(preferredTypes, conformance: metadata.typeConformanceGraph)
        let expandedMappedTypes = mappedTypes.isEmpty
            ? Set<String>()
            : expandTypeIdentifiers(mappedTypes, conformance: metadata.typeConformanceGraph)
        let machineFamilyHint = hardwareMachineFamily(modelIdentifier: normalizedModel, iconName: nil)

        if preferredTypes.isEmpty, let preferredModelTag {
            MirageLogger.host(
                "Host icon color-specific model tag unavailable: \(preferredModelTag), falling back to family/model matching"
            )
        }

        var best: (name: String, score: Int, size: Int)?

        for icon in iconEntries {
            let lowercasedName = icon.lowercasedName
            var score = 0

            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: preferredTypes,
                    exactWeight: 22000,
                    prefixWeight: 20500,
                    containsWeight: 18000
                )
            )
            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: mappedTypes,
                    exactWeight: 15000,
                    prefixWeight: 13500,
                    containsWeight: 11500
                )
            )
            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: expandedPreferredTypes,
                    exactWeight: 9000,
                    prefixWeight: 7800,
                    containsWeight: 6600
                )
            )
            score = max(
                score,
                scoreForTypeMatch(
                    iconName: lowercasedName,
                    typeIdentifiers: expandedMappedTypes,
                    exactWeight: 5200,
                    prefixWeight: 4300,
                    containsWeight: 3500
                )
            )

            guard score > 0 else {
                continue
            }

            score += min(icon.size / 4096, 900)
            if mirageIsMacHardwareIconName(icon.lowercasedName) {
                score += 500
            }
            if let machineFamilyHint,
               mirageMacHardwareIconName(lowercasedName, matchesMachineFamily: machineFamilyHint) {
                score += 1600
            }
            if matchesColorHint(iconName: lowercasedName, colorHints: resolvedPreferredColorHints) {
                score += 2100
            }

            if let currentBest = best {
                if score > currentBest.score || (score == currentBest.score && icon.size > currentBest.size) {
                    best = (name: icon.originalName, score: score, size: icon.size)
                }
            } else {
                best = (name: icon.originalName, score: score, size: icon.size)
            }
        }

        if let resolved = best?.name {
            return resolved
        }

        if let familyFallback = bestFamilyFallbackIconName(
            machineFamily: machineFamilyHint,
            iconEntries: iconEntries,
            preferredColorHints: resolvedPreferredColorHints
        ) {
            return familyFallback
        }

        return iconEntries
            .filter { mirageIsMacHardwareIconName($0.lowercasedName) }
            .max(by: { lhs, rhs in lhs.size < rhs.size })?
            .originalName
    }

    private static func coreTypesBundlePath() -> String? {
        if let bundlePath = Bundle(identifier: "com.apple.CoreTypes")?.bundlePath,
           FileManager.default.fileExists(atPath: bundlePath) {
            return bundlePath
        }

        let fallbacks = [
            "/System/Library/CoreServices/CoreTypes.bundle",
            "/System/Library/Templates/Data/System/Library/CoreServices/CoreTypes.bundle",
        ]
        return fallbacks.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    static func normalizeModelIdentifier(_ value: String?) -> String? {
        guard let normalized = mirageNormalizedHardwareMetadataValue(value) else { return nil }
        if let markerIndex = normalized.firstIndex(of: "@") {
            return String(normalized[..<markerIndex])
        }
        return normalized
    }

    private static func normalizeModelTagIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        var normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let nulIndex = normalized.firstIndex(of: "\u{0}") {
            normalized = String(normalized[..<nulIndex])
        }
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func parseStringCollection(_ value: Any?) -> [String] {
        if let string = value as? String {
            return [string]
        }
        if let strings = value as? [String] {
            return strings
        }
        return []
    }

    private static func parseCoreTypesMetadata(plistPaths: [String]) -> (
        modelTagToTypeIdentifiers: [String: Set<String>],
        modelToTypeIdentifiers: [String: Set<String>],
        typeConformanceGraph: [String: Set<String>]
    ) {
        var modelTagToTypeIdentifiers: [String: Set<String>] = [:]
        var modelToTypeIdentifiers: [String: Set<String>] = [:]
        var typeConformanceGraph: [String: Set<String>] = [:]

        for plistPath in plistPaths {
            guard
                let data = FileManager.default.contents(atPath: plistPath),
                let plistObject = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let plist = plistObject as? [String: Any],
                let declarations = plist["UTExportedTypeDeclarations"] as? [[String: Any]] else {
                continue
            }

            for declaration in declarations {
                guard let typeIdentifier = (declaration["UTTypeIdentifier"] as? String)?
                    .lowercased(), !typeIdentifier.isEmpty else {
                    continue
                }

                let conformsTo = parseStringCollection(declaration["UTTypeConformsTo"])
                    .map { $0.lowercased() }
                if !conformsTo.isEmpty {
                    typeConformanceGraph[typeIdentifier, default: []].formUnion(conformsTo)
                }

                guard let tagSpecification = declaration["UTTypeTagSpecification"] as? [String: Any] else {
                    continue
                }

                let rawModelCodes = parseStringCollection(tagSpecification["com.apple.device-model-code"])
                    .map { normalizeModelTagIdentifier($0) }
                    .compactMap(\.self)
                guard !rawModelCodes.isEmpty else {
                    continue
                }

                let relatedTypes = Set([typeIdentifier] + conformsTo)
                for rawModelCode in rawModelCodes {
                    modelTagToTypeIdentifiers[rawModelCode, default: []].formUnion(relatedTypes)
                    if let baseModelCode = normalizeModelIdentifier(rawModelCode) {
                        modelToTypeIdentifiers[baseModelCode, default: []].formUnion(relatedTypes)
                    }
                }
            }
        }

        return (modelTagToTypeIdentifiers, modelToTypeIdentifiers, typeConformanceGraph)
    }

    private static func expandTypeIdentifiers(
        _ initial: Set<String>,
        conformance: [String: Set<String>]
    ) -> Set<String> {
        var visited = initial
        var queue = Array(initial)

        while let next = queue.popLast() {
            for parent in conformance[next, default: []] where !visited.contains(parent) {
                visited.insert(parent)
                queue.append(parent)
            }
        }

        return visited
    }

    private static func scoreForTypeMatch(
        iconName: String,
        typeIdentifiers: Set<String>,
        exactWeight: Int,
        prefixWeight: Int,
        containsWeight: Int
    ) -> Int {
        guard !typeIdentifiers.isEmpty else {
            return 0
        }

        var bestScore = 0
        for typeIdentifier in typeIdentifiers {
            if iconName == "\(typeIdentifier).icns" {
                bestScore = max(bestScore, exactWeight)
            } else if iconName.hasPrefix(typeIdentifier + "-") {
                bestScore = max(bestScore, prefixWeight)
            } else if iconName.contains(typeIdentifier) {
                bestScore = max(bestScore, containsWeight)
            }
        }

        return bestScore
    }

    private static func bestFamilyFallbackIconName(
        machineFamily: String?,
        iconEntries: [CoreTypesHostIconEntry],
        preferredColorHints: Set<String>
    ) -> String? {
        guard !iconEntries.isEmpty else {
            return nil
        }

        let matching = iconEntries.filter { entry in
            guard mirageIsMacHardwareIconName(entry.lowercasedName) else {
                return false
            }
            guard let machineFamily else {
                return true
            }
            return mirageMacHardwareIconName(entry.lowercasedName, matchesMachineFamily: machineFamily)
        }

        let bestMatching = matching.max { lhs, rhs in
            let lhsColor = matchesColorHint(iconName: lhs.lowercasedName, colorHints: preferredColorHints) ? 8000 : 0
            let rhsColor = matchesColorHint(iconName: rhs.lowercasedName, colorHints: preferredColorHints) ? 8000 : 0
            let lhsScore = lhsColor + lhs.size / 8192
            let rhsScore = rhsColor + rhs.size / 8192
            if lhsScore == rhsScore {
                return lhs.size < rhs.size
            }
            return lhsScore < rhsScore
        }

        if let bestMatching {
            return bestMatching.originalName
        }

        return iconEntries
            .filter { mirageIsMacHardwareIconName($0.lowercasedName) }
            .max(by: { lhs, rhs in lhs.size < rhs.size })?
            .originalName
    }

    private static func preferredColorHints(from typeIdentifiers: Set<String>) -> Set<String> {
        guard !typeIdentifiers.isEmpty else {
            return []
        }

        let knownColorHints = [
            "space-black",
            "space-gray",
            "silver",
            "midnight",
            "starlight",
            "stardust",
            "sky-blue",
            "gold",
            "rose-gold",
            "blue",
        ]

        var hints: Set<String> = []
        for typeIdentifier in typeIdentifiers {
            for colorHint in knownColorHints where typeIdentifier.contains(colorHint) {
                hints.insert(colorHint)
            }
        }
        return hints
    }

    private static func matchesColorHint(iconName: String, colorHints: Set<String>) -> Bool {
        guard !colorHints.isEmpty else {
            return false
        }

        return colorHints.contains { iconName.contains($0) }
    }
}

#endif
