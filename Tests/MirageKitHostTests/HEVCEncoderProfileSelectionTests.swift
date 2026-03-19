//
//  VideoEncoderProfileSelectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Verifies HEVC profile selection by requested pixel format.
//

@testable import MirageKitHost
import MirageKit
import Testing
import VideoToolbox

#if os(macOS)
@Suite("HEVC Encoder Profile Selection")
struct VideoEncoderProfileSelectionTests {
    @Test("ARGB2101010 requests Main42210 then Main10 fallback")
    func argb2101010ProfilePreference() {
        let profiles = VideoEncoder.requestedProfileLevels(for: .bgr10a2)
        #expect(profiles.count == 2)
        #expect(CFEqual(profiles[0], kVTProfileLevel_HEVC_Main42210_AutoLevel))
        #expect(CFEqual(profiles[1], kVTProfileLevel_HEVC_Main10_AutoLevel))
    }

    @Test("P010 requests Main10")
    func p010ProfileSelection() {
        let profiles = VideoEncoder.requestedProfileLevels(for: .p010)
        #expect(profiles.count == 1)
        #expect(CFEqual(profiles[0], kVTProfileLevel_HEVC_Main10_AutoLevel))
    }

    @Test("BGRA and NV12 request Main profile")
    func bgraAndNV12ProfileSelection() {
        let bgraProfiles = VideoEncoder.requestedProfileLevels(for: .bgra8)
        #expect(bgraProfiles.count == 1)
        #expect(CFEqual(bgraProfiles[0], kVTProfileLevel_HEVC_Main_AutoLevel))

        let nv12Profiles = VideoEncoder.requestedProfileLevels(for: .nv12)
        #expect(nv12Profiles.count == 1)
        #expect(CFEqual(nv12Profiles[0], kVTProfileLevel_HEVC_Main_AutoLevel))
    }
}
#endif
