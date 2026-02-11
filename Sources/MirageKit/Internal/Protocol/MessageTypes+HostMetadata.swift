//
//  MessageTypes+HostMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/11/26.
//
//  Host metadata message type definitions.
//

import Foundation

/// Request host hardware icon data from the connected host (Client -> Host).
package struct HostHardwareIconRequestMessage: Codable {
    /// Preferred max pixel dimension for the encoded icon PNG payload.
    package let preferredMaxPixelSize: Int

    package init(preferredMaxPixelSize: Int = 512) {
        self.preferredMaxPixelSize = preferredMaxPixelSize
    }
}

/// Host hardware icon payload (Host -> Client).
package struct HostHardwareIconMessage: Codable {
    /// PNG-encoded icon payload.
    package let pngData: Data
    /// Host-resolved icon basename.
    package let iconName: String?
    /// Host hardware model identifier.
    package let hardwareModelIdentifier: String?
    /// Host machine-family hint (`macBook`, `iMac`, `macMini`, `macStudio`, `macPro`, `macGeneric`).
    package let hardwareMachineFamily: String?

    package init(
        pngData: Data,
        iconName: String?,
        hardwareModelIdentifier: String?,
        hardwareMachineFamily: String?
    ) {
        self.pngData = pngData
        self.iconName = iconName
        self.hardwareModelIdentifier = hardwareModelIdentifier
        self.hardwareMachineFamily = hardwareMachineFamily
    }
}
