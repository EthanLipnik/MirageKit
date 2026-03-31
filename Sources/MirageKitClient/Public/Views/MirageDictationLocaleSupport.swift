//
//  MirageDictationLocaleSupport.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//
//  Supported dictation locale discovery and runtime resolution.
//

#if os(iOS) || os(visionOS)
import Foundation
import Speech

public enum MirageDictationLocaleSupport {
    public static func supportedLocales() async -> [Locale] {
        let locales: [Locale]

        if #available(iOS 26.0, visionOS 26.0, *) {
            if SpeechTranscriber.isAvailable {
                locales = await SpeechTranscriber.supportedLocales
            } else {
                locales = await DictationTranscriber.supportedLocales
            }
        } else {
            locales = Array(SFSpeechRecognizer.supportedLocales())
        }

        return MirageDictationLocaleMatcher
            .uniqueSupportedLocales(from: locales)
            .sorted { lhs, rhs in
                lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedAscending
            }
    }

    public static func resolvedLocale(
        for preference: MirageDictationLocalePreference,
        currentLocale: Locale = .autoupdatingCurrent
    ) async -> Locale? {
        let requestedLocale = preference.locale ?? currentLocale

        if #available(iOS 26.0, visionOS 26.0, *) {
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

        return MirageDictationLocaleMatcher.bestSupportedLocale(
            for: requestedLocale,
            within: SFSpeechRecognizer.supportedLocales()
        )
    }
}
#endif
