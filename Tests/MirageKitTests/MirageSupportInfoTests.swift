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

    @Test("Chip names map reported iPad hardware identifiers")
    func chipNamesMapReportedIPadHardwareIdentifiers() {
        #expect(MirageSupportInfo.chipName(for: "iPad13,8") == "Apple M1")
        #expect(MirageSupportInfo.chipName(for: "iPad14,5") == "Apple M2")
        #expect(MirageSupportInfo.chipName(for: "iPad16,6") == "Apple M4")
        #expect(MirageSupportInfo.chipName(for: "UnknownBoard") == "Unknown")
    }
}
