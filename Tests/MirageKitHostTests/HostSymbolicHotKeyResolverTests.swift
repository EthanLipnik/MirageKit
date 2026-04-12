//
//  HostSymbolicHotKeyResolverTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Symbolic Hot Key Resolver")
struct HostSymbolicHotKeyResolverTests {
    @Test("Mission Control resolves the configured symbolic hotkey")
    func missionControlResolvesConfiguredSymbolicHotkey() {
        let resolution = HostSymbolicHotKeyResolver.resolve(
            .missionControl,
            propertyList: [
                "AppleSymbolicHotKeys": [
                    "32": [
                        "enabled": true,
                        "value": [
                            "parameters": [65535, 126, 786_432],
                            "type": "standard",
                        ],
                    ],
                ],
            ]
        )

        guard case let .shortcut(keyEvent) = resolution else {
            Issue.record("Expected a resolved shortcut")
            return
        }

        #expect(keyEvent.keyCode == 126)
        #expect(keyEvent.modifiers == [.control, .option])
    }

    @Test("Space switching resolves using the host symbolic hotkey entry")
    func spaceSwitchingResolvesUsingHostEntry() {
        let resolution = HostSymbolicHotKeyResolver.resolve(
            .spaceLeft,
            propertyList: [
                "AppleSymbolicHotKeys": [
                    "79": [
                        "enabled": true,
                        "value": [
                            "parameters": [65535, 123, 262_144],
                            "type": "standard",
                        ],
                    ],
                ],
            ]
        )

        guard case let .shortcut(keyEvent) = resolution else {
            Issue.record("Expected a resolved shortcut")
            return
        }

        #expect(keyEvent.keyCode == 123)
        #expect(keyEvent.modifiers == [.control])
    }

    @Test("Disabled entries remain disabled")
    func disabledEntriesRemainDisabled() {
        let resolution = HostSymbolicHotKeyResolver.resolve(
            .appExpose,
            propertyList: [
                "AppleSymbolicHotKeys": [
                    "33": [
                        "enabled": false,
                        "value": [
                            "parameters": [65535, 125, 262_144],
                            "type": "standard",
                        ],
                    ],
                ],
            ]
        )

        #expect(resolution == .disabled)
    }

    @Test("Missing entries remain unavailable")
    func missingEntriesRemainUnavailable() {
        let resolution = HostSymbolicHotKeyResolver.resolve(
            .missionControl,
            propertyList: [:]
        )

        #expect(resolution == .unavailable)
    }
}
#endif
