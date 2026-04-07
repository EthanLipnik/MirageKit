//
//  MirageStreamingSettingsLowPowerTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import Foundation
import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Streaming Settings Low-Power Defaults")
struct MirageStreamingSettingsLowPowerTests {
    @Test("Legacy settings decode defaults encoder low-power preference to auto")
    func legacyDecodeDefaultsEncoderLowPowerPreference() throws {
        let legacyJSON = """
        {
          "closeHostWindowOnClientWindowClose": true,
          "perAppSettings": {
            "com.example.test": {
              "allowStreaming": false
            }
          }
        }
        """

        let decoded = try JSONDecoder().decode(
            MirageStreamingSettings.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.closeHostWindowOnClientWindowClose)
        #expect(decoded.encoderLowPowerModePreference == .auto)
        #expect(decoded.perAppSettings["com.example.test"]?.allowStreaming == false)
    }

    @Test("Encoder low-power preference survives codable roundtrip")
    func encoderLowPowerPreferenceRoundtrip() throws {
        let source = MirageStreamingSettings(
            closeHostWindowOnClientWindowClose: false,
            encoderLowPowerModePreference: .onlyOnBattery,
            perAppSettings: ["com.example.app": MirageAppStreamingSettings(allowStreaming: true)]
        )

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(MirageStreamingSettings.self, from: encoded)

        #expect(decoded.encoderLowPowerModePreference == .onlyOnBattery)
    }
}
