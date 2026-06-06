//
//  MirageCustomStreamDescriptorTests.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia
import Testing

@Suite("MirageMedia Custom Stream Descriptor")
struct MirageCustomStreamDescriptorTests {
    @Test("Custom stream descriptor normalizes dimensions and frame rate")
    func customStreamDescriptorNormalizesDimensionsAndFrameRate() throws {
        let descriptor = MirageMedia.MirageCustomStreamDescriptor(
            kind: "dev.example.custom.v1",
            displayName: "Example Custom Stream",
            metadata: ["purpose": "test"],
            defaultWidth: 0,
            defaultHeight: -4,
            defaultFrameRate: 500,
            supportsInput: false
        )
        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(MirageMedia.MirageCustomStreamDescriptor.self, from: encoded)

        #expect(descriptor.defaultWidth == 1)
        #expect(descriptor.defaultHeight == 1)
        #expect(descriptor.defaultFrameRate == 120)
        #expect(descriptor.supportsInput == false)
        #expect(decoded == descriptor)
    }
}
