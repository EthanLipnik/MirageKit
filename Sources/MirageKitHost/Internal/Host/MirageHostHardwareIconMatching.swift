//
//  MirageHostHardwareIconMatching.swift
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

/// Lowercases and trims a hardware metadata string, returning nil when it is empty.
func mirageNormalizedHardwareMetadataValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return normalized
}

/// Returns true when a lowercased CoreTypes icon name appears to describe Mac hardware.
func mirageIsMacHardwareIconName(_ lowercasedName: String) -> Bool {
    lowercasedName.contains("macbook") ||
        lowercasedName.contains("imac") ||
        lowercasedName.contains("macmini") ||
        lowercasedName.contains("macstudio") ||
        lowercasedName.contains("macpro") ||
        lowercasedName.contains("sidebarlaptop") ||
        lowercasedName.contains("sidebarmac")
}

/// Returns true when a lowercased CoreTypes icon name matches a normalized Mac family hint.
func mirageMacHardwareIconName(_ iconName: String, matchesMachineFamily family: String) -> Bool {
    switch family.lowercased() {
    case "macbook":
        iconName.contains("macbook") || iconName.contains("sidebarlaptop")
    case "imac":
        iconName.contains("imac") || iconName.contains("sidebarimac")
    case "macmini":
        iconName.contains("macmini") || iconName.contains("sidebarmacmini")
    case "macstudio":
        iconName.contains("macstudio")
    case "macpro":
        iconName.contains("macpro") || iconName.contains("sidebarmacpro")
    default:
        mirageIsMacHardwareIconName(iconName)
    }
}
