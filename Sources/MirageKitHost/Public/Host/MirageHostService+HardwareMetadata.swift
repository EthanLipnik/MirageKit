//
//  MirageHostService+HardwareMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import Foundation

#if os(macOS)
import Darwin

// MARK: - Host Hardware Metadata

extension MirageHostService {
    static func hardwareModelIdentifier() -> String? {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String.mirageDecodedCString(buffer)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func detectSupportedColorDepths() -> [MirageMedia.MirageStreamColorDepth] {
        let ultraProbe = UltraColorDepthProbeCache.result
        var supported: [MirageMedia.MirageStreamColorDepth] = [.standard, .pro]
        if ultraProbe.supportsUltra444 {
            supported.append(.ultra)
        }

        let chromaText = ultraProbe.encodedChromaSampling?.rawValue ?? "unknown"
        let hardwareText = ultraProbe.usingHardwareEncoder.map { String($0) } ?? "unknown"
        MirageLogger.host(
            "Color depth support: supported=\(supported.map(\.rawValue).joined(separator: ",")) " +
                "ultraCaptureXF44=\(ultraProbe.captureAcceptsXF44) " +
                "ultraSessionCreated=\(ultraProbe.encoderSessionCreated) " +
                "ultraChroma=\(chromaText) " +
                "ultraHardware=\(hardwareText)"
        )

        return supported
    }

    static func detectProRes4444Support() -> Bool {
        let supported = ProRes4444SupportProbeCache.supported
        MirageLogger.host("ProRes 4444 support: \(supported)")
        return supported
    }

    private enum UltraColorDepthProbeCache {
        static let result = VideoEncoder.probeStrictUltra444Support()
    }

    private enum ProRes4444SupportProbeCache {
        static let supported = VideoEncoder.probeProRes4444Support()
    }

    func effectiveVideoCodec(for requested: MirageMedia.MirageVideoCodec?) -> MirageMedia.MirageVideoCodec? {
        guard requested == .proRes4444 else { return requested }
        guard supportsProRes4444 else {
            MirageLogger.host("ProRes 4444 request ignored because this host does not support ProRes 4444")
            return nil
        }
        return .proRes4444
    }

    func effectiveColorDepth(
        for requested: MirageMedia.MirageStreamColorDepth?,
        codec: MirageMedia.MirageVideoCodec? = nil
    ) -> MirageMedia.MirageStreamColorDepth? {
        guard let requested else { return nil }
        if codec == .proRes4444, requested == .ultra, supportsProRes4444 {
            return .ultra
        }
        if supportedColorDepths.contains(requested) {
            return requested
        }

        return supportedColorDepths
            .filter { $0.sortRank <= requested.sortRank }
            .max(by: { lhs, rhs in
                lhs.sortRank < rhs.sortRank
            })
            ?? supportedColorDepths.first
            ?? .standard
    }

    static func hardwareMachineFamily(modelIdentifier: String?, iconName: String?) -> String? {
        if let modelIdentifier,
           let family = hardwareMachineFamily(forKnownModelIdentifier: modelIdentifier) {
            return family
        }

        if let iconName {
            let normalizedIconName = iconName.lowercased()
            if normalizedIconName.contains("macbook") || normalizedIconName.contains("sidebarlaptop") {
                return "macBook"
            }
            if normalizedIconName.contains("imac") || normalizedIconName.contains("sidebarimac") {
                return "iMac"
            }
            if normalizedIconName.contains("macmini") || normalizedIconName.contains("sidebarmacmini") {
                return "macMini"
            }
            if normalizedIconName.contains("macstudio") {
                return "macStudio"
            }
            if normalizedIconName.contains("macpro") || normalizedIconName.contains("sidebarmacpro") {
                return "macPro"
            }
        }

        if let modelIdentifier {
            let normalizedModel = modelIdentifier.lowercased()
            if normalizedModel.contains("macbook") {
                return "macBook"
            }
            if normalizedModel.contains("imac") {
                return "iMac"
            }
            if normalizedModel.contains("macmini") {
                return "macMini"
            }
            if normalizedModel.contains("macstudio") {
                return "macStudio"
            }
            if normalizedModel.contains("macpro") {
                return "macPro"
            }
        }

        guard let machineName = hardwareMachineName()?.lowercased() else {
            return "macGeneric"
        }
        if machineName.contains("macbook") {
            return "macBook"
        }
        if machineName.contains("imac") {
            return "iMac"
        }
        if machineName.contains("mini") {
            return "macMini"
        }
        if machineName.contains("studio") {
            return "macStudio"
        }
        if machineName.contains("pro") {
            return "macPro"
        }
        return "macGeneric"
    }

    private static func hardwareMachineFamily(forKnownModelIdentifier modelIdentifier: String) -> String? {
        guard let normalizedModel = normalizeModelIdentifier(modelIdentifier) else {
            return nil
        }

        switch normalizedModel {
        case "mac13,1",
             "mac13,2",
             "mac14,13",
             "mac14,14",
             "mac15,14",
             "mac16,9":
            return "macStudio"
        case "mac14,3",
             "mac14,12",
             "mac16,10",
             "mac16,11":
            return "macMini"
        default:
            return nil
        }
    }

    private static func hardwareMachineName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout before waiting for exit so verbose subprocess output
        // cannot fill the pipe buffer and block startup.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: outputData),
            let dictionary = jsonObject as? [String: Any],
            let hardwareEntries = dictionary["SPHardwareDataType"] as? [[String: Any]],
            let firstEntry = hardwareEntries.first,
            let machineName = firstEntry["machine_name"] as? String else {
            return nil
        }

        let trimmed = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}

#endif
