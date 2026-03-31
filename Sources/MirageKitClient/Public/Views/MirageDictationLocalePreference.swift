//
//  MirageDictationLocalePreference.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//
//  Dictation locale selection and supported-locale matching.
//

import Foundation

public enum MirageDictationLocalePreference: RawRepresentable, Sendable, Hashable {
    case system
    case locale(Locale)

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .system
            return
        }
        self = .locale(Locale(identifier: Self.canonicalIdentifier(from: trimmed)))
    }

    public var rawValue: String {
        switch self {
        case .system:
            ""
        case let .locale(locale):
            Self.canonicalIdentifier(from: locale.identifier)
        }
    }

    public var locale: Locale? {
        switch self {
        case .system:
            nil
        case let .locale(locale):
            locale
        }
    }

    public var isSystemDefault: Bool {
        switch self {
        case .system:
            true
        case .locale:
            false
        }
    }

    static func canonicalIdentifier(from identifier: String) -> String {
        Components(identifier: identifier).canonicalIdentifier
    }
}

struct MirageDictationLocaleMatcher {
    static func bestSupportedLocale<S: Sequence>(
        for requestedLocale: Locale,
        within supportedLocales: S
    ) -> Locale? where S.Element == Locale {
        let uniqueLocales = uniqueSupportedLocales(from: supportedLocales)
        guard !uniqueLocales.isEmpty else { return nil }

        let requestedComponents = Components(locale: requestedLocale)
        if let exactMatch = uniqueLocales.first(where: {
            Components(locale: $0).canonicalIdentifier == requestedComponents.canonicalIdentifier
        }) {
            return exactMatch
        }

        return uniqueLocales
            .compactMap { candidate -> ScoredLocale? in
                let candidateComponents = Components(locale: candidate)
                guard let score = requestedComponents.matchScore(for: candidateComponents) else { return nil }
                return ScoredLocale(
                    locale: candidate,
                    score: score,
                    canonicalIdentifier: candidateComponents.canonicalIdentifier
                )
            }
            .max { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.canonicalIdentifier > rhs.canonicalIdentifier
                }
                return lhs.score < rhs.score
            }?
            .locale
    }

    static func uniqueSupportedLocales<S: Sequence>(from locales: S) -> [Locale] where S.Element == Locale {
        var seenIdentifiers: Set<String> = []
        var uniqueLocales: [Locale] = []

        for locale in locales {
            let identifier = Components(locale: locale).canonicalIdentifier
            guard seenIdentifiers.insert(identifier).inserted else { continue }
            uniqueLocales.append(Locale(identifier: identifier))
        }

        return uniqueLocales
    }
}

private struct ScoredLocale {
    let locale: Locale
    let score: Int
    let canonicalIdentifier: String
}

private struct Components {
    let canonicalIdentifier: String
    let languageCode: String?
    let scriptCode: String?
    let regionCode: String?
    let specificity: Int

    init(identifier: String) {
        let normalizedIdentifier = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "@", maxSplits: 1)
            .first
            .map(String.init)?
            .replacingOccurrences(of: "_", with: "-") ?? ""
        let subtags = normalizedIdentifier
            .split(separator: "-")
            .map(String.init)

        let parsedLanguageCode = subtags.first?.lowercased()
        var parsedScriptCode: String?
        var parsedRegionCode: String?

        for subtag in subtags.dropFirst() {
            if parsedScriptCode == nil,
               subtag.count == 4,
               subtag.allSatisfy(\.isLetter) {
                parsedScriptCode = subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
                continue
            }

            if parsedRegionCode == nil,
               ((subtag.count == 2 && subtag.allSatisfy(\.isLetter)) ||
               (subtag.count == 3 && subtag.allSatisfy(\.isNumber))) {
                parsedRegionCode = subtag.uppercased()
            }
        }

        languageCode = parsedLanguageCode
        scriptCode = parsedScriptCode?.lowercased()
        regionCode = parsedRegionCode?.lowercased()

        let canonicalParts = [parsedLanguageCode, parsedScriptCode, parsedRegionCode].compactMap { $0 }
        canonicalIdentifier = canonicalParts.isEmpty ? normalizedIdentifier : canonicalParts.joined(separator: "-")
        specificity = [scriptCode, regionCode].compactMap { $0 }.count
    }

    init(locale: Locale) {
        self.init(identifier: locale.identifier)
    }

    func matchScore(for candidate: Components) -> Int? {
        guard let languageCode, languageCode == candidate.languageCode else { return nil }

        var score = 100

        if let scriptCode {
            if candidate.scriptCode == scriptCode {
                score += 20
            } else if candidate.scriptCode == nil {
                score += 5
            } else {
                score -= 25
            }
        } else if candidate.scriptCode != nil {
            score -= 1
        }

        if let regionCode {
            if candidate.regionCode == regionCode {
                score += 10
            } else if candidate.regionCode == nil {
                score += 2
            } else {
                score -= 5
            }
        } else if candidate.regionCode != nil {
            score -= 1
        }

        score -= abs(specificity - candidate.specificity)
        return score
    }
}
