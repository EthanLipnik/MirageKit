//
//  MirageDictationLocalePreferenceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/30/26.
//

import Foundation
import Testing
@testable import MirageKitClient

struct MirageDictationLocalePreferenceTests {
    @Test("System preference stores an empty raw value")
    func systemPreferenceRawValue() {
        let preference = MirageDictationLocalePreference.system

        #expect(preference.rawValue.isEmpty)
        #expect(preference.locale == nil)
        #expect(preference.isSystemDefault)
    }

    @Test("Specific locale preferences are canonicalized")
    func localePreferenceCanonicalization() {
        let preference = MirageDictationLocalePreference(rawValue: "EN-us")

        #expect(preference.locale != nil)
        #expect(
            preference.rawValue == MirageDictationLocalePreference.canonicalIdentifier(from: "EN-us")
        )
    }

    @Test("Matcher returns an exact supported locale when present")
    func matcherPrefersExactMatch() {
        let supportedLocales = [
            Locale(identifier: "en-GB"),
            Locale(identifier: "en-US"),
        ]

        let matchedLocale = MirageDictationLocaleMatcher.bestSupportedLocale(
            for: Locale(identifier: "en-US"),
            within: supportedLocales
        )

        #expect(matchedLocale?.identifier == Locale(identifier: "en-US").identifier)
    }

    @Test("Matcher prefers matching script when the exact locale is unavailable")
    func matcherPrefersMatchingScript() {
        let supportedLocales = [
            Locale(identifier: "zh-Hans-CN"),
            Locale(identifier: "zh-Hant-TW"),
        ]

        let matchedLocale = MirageDictationLocaleMatcher.bestSupportedLocale(
            for: Locale(identifier: "zh-Hant-HK"),
            within: supportedLocales
        )

        #expect(matchedLocale?.identifier == Locale(identifier: "zh-Hant-TW").identifier)
    }

    @Test("Matcher returns nil when no supported locale shares the requested language")
    func matcherReturnsNilForUnsupportedLanguage() {
        let supportedLocales = [
            Locale(identifier: "en_US"),
            Locale(identifier: "fr_FR"),
        ]

        let matchedLocale = MirageDictationLocaleMatcher.bestSupportedLocale(
            for: Locale(identifier: "ja_JP"),
            within: supportedLocales
        )

        #expect(matchedLocale == nil)
    }
}
