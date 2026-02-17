//
//  PixelFormatDisplayNameTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/10/26.
//
//  Verifies user-facing pixel format labels match encoded chroma behavior.
//

import Foundation
import MirageKit
import Testing

@Suite("Pixel Format Display Names")
struct PixelFormatDisplayNameTests {
    @Test("RGB inputs no longer claim unconditional 4:4:4")
    func rgbInputLabelsAvoid444Claim() {
        let argbLabel = MiragePixelFormat.bgr10a2.displayName
        let bgraLabel = MiragePixelFormat.bgra8.displayName

        #expect(!argbLabel.localizedStandardContains("4:4:4"))
        #expect(!bgraLabel.localizedStandardContains("4:4:4"))
    }

    @Test("YUV inputs use concise pixel format labels")
    func yuvInputLabelsAreConcise() {
        let p010Label = MiragePixelFormat.p010.displayName
        let nv12Label = MiragePixelFormat.nv12.displayName

        #expect(p010Label == "10-bit (P010)")
        #expect(nv12Label == "8-bit (NV12)")
    }
}
