//
//  CGVirtualDisplayBridge+ModeConstruction.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Runtime construction of CGVirtualDisplay modes and settings.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreVideo
import Foundation

#if os(macOS)
extension CGVirtualDisplayBridge {
    private static let transferFunctionCodeSRGB = UInt32(
        CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_sRGB)
    )
    private static let transferFunctionCode709 = UInt32(
        CVTransferFunctionGetIntegerCodePointForString(kCVImageBufferTransferFunction_ITU_R_709_2)
    )
    private static let transferFunctionCodeUnknown: UInt32 = 2

    struct ModeActivationAttempt {
        let modeWidth: Int
        let modeHeight: Int
        let hiDPISetting: UInt32
        let label: String
    }

    struct TransferFunctionAttempt {
        let code: UInt32
        let label: String
    }

    /// Constructs a CGVirtualDisplayMode through the private runtime API.
    static func createDisplayMode(
        modeClass: NSObject.Type,
        width: Int,
        height: Int,
        refreshRate: Double,
        transferFunction: UInt32
    )
    -> AnyObject? {
        let allocSelector = NSSelectorFromString("alloc")
        guard let allocatedMode = (modeClass as AnyObject).perform(allocSelector)?.takeUnretainedValue() else {
            MirageLogger.error(.host, "Failed to allocate CGVirtualDisplayMode")
            return nil
        }

        let initWithTransferFunctionSelector = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
        let initSelector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let setTransferFunctionSelector = NSSelectorFromString("setTransferFunction:")

        let initialized: AnyObject
        if (allocatedMode as AnyObject).responds(to: initWithTransferFunctionSelector) {
            typealias InitModeWithTransferFunctionIMP = @convention(c)
                (AnyObject, Selector, UInt32, UInt32, Double, UInt32) -> Unmanaged<AnyObject>
            let initIMP = (allocatedMode as AnyObject).method(for: initWithTransferFunctionSelector)
            let initialize = unsafeBitCast(initIMP, to: InitModeWithTransferFunctionIMP.self)
            initialized = initialize(
                allocatedMode as AnyObject,
                initWithTransferFunctionSelector,
                UInt32(width),
                UInt32(height),
                refreshRate,
                transferFunction
            ).takeRetainedValue()
        } else {
            guard (allocatedMode as AnyObject).responds(to: initSelector) else {
                MirageLogger.error(
                    .host,
                    "CGVirtualDisplayMode doesn't respond to initWithWidth:height:refreshRate: or initWithWidth:height:refreshRate:transferFunction:"
                )
                return nil
            }
            typealias InitModeIMP = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>
            let initIMP = (allocatedMode as AnyObject).method(for: initSelector)
            let initialize = unsafeBitCast(initIMP, to: InitModeIMP.self)
            initialized = initialize(
                allocatedMode as AnyObject,
                initSelector,
                UInt32(width),
                UInt32(height),
                refreshRate
            ).takeRetainedValue()
        }

        if (initialized as AnyObject).responds(to: setTransferFunctionSelector) {
            typealias SetTransferFunctionIMP = @convention(c) (AnyObject, Selector, UInt32) -> Void
            let setTransferFunctionIMP = (initialized as AnyObject).method(for: setTransferFunctionSelector)
            let setTransferFunction = unsafeBitCast(setTransferFunctionIMP, to: SetTransferFunctionIMP.self)
            setTransferFunction(initialized as AnyObject, setTransferFunctionSelector, transferFunction)
        }

        return initialized
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

    /// Returns the ordered transfer-function tags to try for virtual-display modes.
    static func transferFunctionAttempts() -> [TransferFunctionAttempt] {
        let preferred = TransferFunctionAttempt(
            code: transferFunctionCodeSRGB,
            label: "sRGB(\(transferFunctionCodeSRGB))"
        )
        let rec709 = TransferFunctionAttempt(
            code: transferFunctionCode709,
            label: "ITU-R-709(\(transferFunctionCode709))"
        )
        let unknown = TransferFunctionAttempt(
            code: transferFunctionCodeUnknown,
            label: "unknown(\(transferFunctionCodeUnknown))"
        )

        // Display P3 and sRGB both use SDR transfer functions; prefer explicit sRGB tagging first.
        let ordered = [preferred, rec709, unknown]
        var deduped: [TransferFunctionAttempt] = []
        var seen = Set<UInt32>()
        for candidate in ordered where seen.insert(candidate.code).inserted {
            deduped.append(candidate)
        }
        return deduped
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
