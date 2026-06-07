//
//  MirageDictationLocaleSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//
//  Supported dictation locale discovery and runtime resolution.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(iOS) || os(visionOS)
import Foundation
import Speech

/// Resolves dictation locales supported by the active Apple speech stack.
public enum MirageDictationLocaleSupport {
    /// Returns unique supported dictation locales sorted by locale identifier.
    public static func supportedLocales() async -> [Locale] {
        let locales: [Locale]
        if SpeechTranscriber.isAvailable {
            locales = await SpeechTranscriber.supportedLocales
        } else {
            locales = await DictationTranscriber.supportedLocales
        }

        return MirageDictationLocaleMatcher
            .uniqueSupportedLocales(from: locales)
            .sorted { lhs, rhs in
                lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedAscending
            }
    }

    /// Returns the best available dictation locale for the stored preference and current locale.
    public static func resolvedLocale(
        for preference: MirageDictationLocalePreference,
        currentLocale: Locale = .autoupdatingCurrent
    ) async -> Locale? {
        let requestedLocale = preference.locale ?? currentLocale

        if SpeechTranscriber.isAvailable {
            if let equivalentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
                return equivalentLocale
            }
            let supportedLocales = await SpeechTranscriber.supportedLocales
            return MirageDictationLocaleMatcher.bestSupportedLocale(for: requestedLocale, within: supportedLocales)
        }

        if let equivalentLocale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            return equivalentLocale
        }
        let supportedLocales = await DictationTranscriber.supportedLocales
        return MirageDictationLocaleMatcher.bestSupportedLocale(for: requestedLocale, within: supportedLocales)
    }
}
#endif
