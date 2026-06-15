//
//  CGVirtualDisplayBridge+ModeConstruction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Runtime construction of CGVirtualDisplay modes and settings.
//

import Foundation
import MirageKit

#if os(macOS)
extension CGVirtualDisplayBridge {
    struct ModeActivationAttempt {
        let modeWidth: Int
        let modeHeight: Int
        let hiDPISetting: UInt32
        let label: String
    }

    struct TransferFunctionAttempt {
        let label: String
    }

    /// Constructs a CGVirtualDisplayMode through the private runtime API.
    static func createDisplayMode(
        modeClass: NSObject.Type,
        width: Int,
        height: Int,
        refreshRate: Double
    )
    -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocatedMode = (modeClass as AnyObject).perform(allocSelector)?.takeUnretainedValue() else {
            MirageLogger.error(.host, "Failed to allocate CGVirtualDisplayMode")
            return nil
        }

        let initSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard (allocatedMode as AnyObject).responds(to: initSelector) else {
            MirageLogger.error(.host, "CGVirtualDisplayMode doesn't respond to initWithWidth:height:refreshRate:")
            return nil
        }

        typealias InitModeIMP = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>
        let initIMP = (allocatedMode as AnyObject).method(for: initSelector)
        let initialize = unsafeBitCast(initIMP, to: InitModeIMP.self)
        return initialize(
            allocatedMode as AnyObject,
            initSelector,
            UInt32(width),
            UInt32(height),
            refreshRate
        ).takeRetainedValue()
    }

    /// Applies private virtual-display settings to an allocated display object.
    static func applySettings(
        _ settings: AnyObject,
        to display: AnyObject
    )
    -> Bool {
        let applySelector = NSSelectorFromString("applySettings:")
        guard (display as AnyObject).responds(to: applySelector) else {
            MirageLogger.error(.host, "CGVirtualDisplay doesn't respond to applySettings:")
            return false
        }

        typealias ApplySettingsIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let applyIMP = (display as AnyObject).method(for: applySelector)
        let apply = unsafeBitCast(applyIMP, to: ApplySettingsIMP.self)
        return apply(display as AnyObject, applySelector, settings)
    }

    /// Returns the ordered mode-size and HiDPI settings to attempt for an activation.
    static func modeActivationAttempts(
        pixelWidth: Int,
        pixelHeight: Int,
        hiDPI: Bool
    )
    -> [ModeActivationAttempt] {
        guard hiDPI else {
            return [ModeActivationAttempt(
                modeWidth: pixelWidth,
                modeHeight: pixelHeight,
                hiDPISetting: hiDPIDisabledSetting,
                label: "pixel-hiDPI0"
            )]
        }

        let logicalWidth = max(1, pixelWidth / 2)
        let logicalHeight = max(1, pixelHeight / 2)
        let candidates: [ModeActivationAttempt] = [
            ModeActivationAttempt(
                modeWidth: logicalWidth,
                modeHeight: logicalHeight,
                hiDPISetting: hiDPIEnabledSetting,
                label: "logical-hiDPI\(hiDPIEnabledSetting)"
            ),
        ]

        var deduped: [ModeActivationAttempt] = []
        var seen = Set<String>()
        for candidate in candidates {
            let key = "\(candidate.modeWidth)x\(candidate.modeHeight)-\(candidate.hiDPISetting)"
            if seen.insert(key).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    /// Returns the transfer-function policy to use for virtual-display modes.
    static func transferFunctionAttempts() -> [TransferFunctionAttempt] {
        [TransferFunctionAttempt(label: "descriptor-default")]
    }

    /// Reads the private transfer-function tag from a CGVirtualDisplayMode when exposed.
    static func modeTransferFunction(_ mode: AnyObject) -> UInt32? {
        let selector = NSSelectorFromString("transferFunction")
        guard (mode as AnyObject).responds(to: selector) else { return nil }
        typealias GetTransferFunctionIMP = @convention(c) (AnyObject, Selector) -> UInt32
        let imp = (mode as AnyObject).method(for: selector)
        let getter = unsafeBitCast(imp, to: GetTransferFunctionIMP.self)
        return getter(mode as AnyObject, selector)
    }
}
#endif
