//
//  MiragePencilGestureConfigurationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

@testable import MirageKitClient
import Foundation
import Testing

@Suite("Pencil Gesture Configuration")
struct MiragePencilGestureConfigurationTests {
    @Test("Default configuration maps double tap to dictation and squeeze to secondary click")
    func defaultConfigurationValues() {
        #expect(MiragePencilGestureConfiguration.default.doubleTap == .toggleDictation)
        #expect(MiragePencilGestureConfiguration.default.squeeze == .secondaryClick)
    }

    @Test("Configuration codable round trip preserves remote shortcuts")
    func codableRoundTrip() throws {
        let configuration = MiragePencilGestureConfiguration(
            doubleTap: .remoteShortcut(MirageClientShortcut(keyCode: 0x15, modifiers: [.command, .shift])),
            squeeze: .none
        )

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(MiragePencilGestureConfiguration.self, from: encoded)

        #expect(decoded == configuration)
    }
}
