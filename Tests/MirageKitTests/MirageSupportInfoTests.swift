//
//  MirageSupportInfoTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

@testable import MirageKit
import Testing

struct MirageSupportInfoTests {
    @Test("Device display names map common hardware identifiers")
    func deviceDisplayNamesMapHardwareIdentifiers() {
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPhone17,1") == "iPhone")
        #expect(MirageSupportInfo.deviceDisplayName(for: "iPad16,3") == "iPad")
        #expect(MirageSupportInfo.deviceDisplayName(for: "RealityDevice14,1") == "Apple Vision Pro")
        #expect(MirageSupportInfo.deviceDisplayName(for: "N301AP") == "Apple Vision Pro")
        #expect(MirageSupportInfo.deviceDisplayName(for: "MacBookPro18,2") == "MacBook Pro")
        #expect(MirageSupportInfo.deviceDisplayName(for: "Macmini9,1") == "Mac mini")
        #expect(MirageSupportInfo.deviceDisplayName(for: "VirtualMac2,1") == "Mac")
        #expect(MirageSupportInfo.deviceDisplayName(for: "UnknownBoard") == "Unknown")
    }
}
