//
//  MirageStreamingSettingsCompatibilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import Foundation
import MirageKitHost
import Testing

@Suite("Mirage Streaming Settings Compatibility")
struct MirageStreamingSettingsCompatibilityTests {
    @Test("Current host streaming settings payload decodes")
    func currentHostStreamingSettingsPayloadDecodes() throws {
        let data = Data(
            """
            {
              "closeHostWindowOnClientWindowClose": true,
              "encoderLowPowerModePreference": "onlyOnBattery",
              "perAppSettings": {
                "com.example.editor": {
                  "allowStreaming": false
                },
                "com.example.viewer": {
                  "allowStreaming": true
                }
              }
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(MirageStreamingSettings.self, from: data)

        #expect(settings.closeHostWindowOnClientWindowClose)
        #expect(settings.encoderLowPowerModePreference == .onlyOnBattery)
        #expect(settings.perAppSettings["com.example.editor"]?.allowStreaming == false)
        #expect(settings.perAppSettings["com.example.viewer"]?.allowStreaming == true)
        #expect(Set(settings.blockedApps) == ["com.example.editor"])
    }
}
