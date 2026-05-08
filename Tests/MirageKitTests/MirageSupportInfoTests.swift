//
//  MirageSupportInfoTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

@testable import MirageKit
import Testing

@Suite("Mirage Support Info Tests")
struct MirageSupportInfoTests {
    @Test("Hardware model identifiers resolve to descriptive device names")
    func hardwareModelIdentifiersResolveToDescriptiveDeviceNames() {
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPhone18,4") == "iPhone Air")
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPhone18,5") == "iPhone 17e")
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPhone17,5") == "iPhone 16e")
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPad17,1") == "iPad Pro 11-inch (M5)")
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPad16,10") == "iPad Air 13-inch (M4)")
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPad16,1") == "iPad mini (A17 Pro)")
        #expect(MirageSupportInfo.deviceDisplayName(for: "Mac16,10") == "Mac mini")
        #expect(MirageSupportInfo.deviceDisplayName(for: "Unknown") == "Unknown")
    }
}
