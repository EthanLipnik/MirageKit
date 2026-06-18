//
//  CGVirtualDisplayBridge+Allocation.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit

extension CGVirtualDisplayBridge {
    /// Populates the private CGVirtualDisplay descriptor for one descriptor attempt.
    static func configureDescriptor(
        _ descriptor: NSObject,
        name: String,
        width: Int,
        height: Int,
        ppi: Double,
        profile: DescriptorAttempt
    ) {
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(mirageVendorID, forKey: "vendorID")
        descriptor.setValue(mirageProductID, forKey: "productID")
        descriptor.setValue(profile.serial, forKey: "serialNum")
        descriptor.setValue(UInt32(width), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(height), forKey: "maxPixelsHigh")
        descriptor.setValue(
            CGSize(width: 25.4 * Double(width) / ppi, height: 25.4 * Double(height) / ppi),
            forKey: "sizeInMillimeters"
        )

        descriptor.setValue(profile.queue, forKey: "queue")
    }

    /// Allocates and initializes a private CGVirtualDisplay instance.
    static func allocateVirtualDisplay(
        displayClass: NSObject.Type,
        descriptor: NSObject,
        profile: DescriptorAttempt
    ) -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocatedDisplay = (displayClass as AnyObject).perform(allocSelector)?
            .takeUnretainedValue() else {
            MirageLogger.error(.host, "Failed to allocate CGVirtualDisplay")
            return nil
        }

        let initSelector = NSSelectorFromString("initWithDescriptor:")
        guard (allocatedDisplay as AnyObject).responds(to: initSelector) else {
            MirageLogger.error(.host, "CGVirtualDisplay doesn't respond to initWithDescriptor:")
            return nil
        }

        guard let display = (allocatedDisplay as AnyObject).perform(initSelector, with: descriptor)?
            .takeRetainedValue() else {
            logVirtualDisplayCreationProbeFailure(profileLabel: profile.label)
            return nil
        }
        return display as AnyObject
    }

    /// Invalidates a private CGVirtualDisplay object when activation or validation fails.
    static func invalidateVirtualDisplay(_ display: AnyObject) {
        let invalidateSelector = NSSelectorFromString("invalidate")
        if display.responds(to: invalidateSelector) {
            _ = display.perform(invalidateSelector)
        }
    }
}
#endif
