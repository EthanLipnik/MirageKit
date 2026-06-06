//
//  MirageClientService+NetworkEndpointUtilities.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Client network endpoint helpers.
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
import Network

@MainActor
extension MirageClientService {
    // MARK: - Network Endpoint Utilities

    private nonisolated static let bonjourBareHostAllowedScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    )

    /// Returns endpoint host candidates for connection attempts, qualifying bare Bonjour names with `.local`.
    nonisolated static func expandedBonjourHosts(for host: NWEndpoint.Host) -> [NWEndpoint.Host] {
        let rawValue = String(describing: host).trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldQualifyBonjourHostWithLocalDomain(rawValue) else { return [host] }
        return [NWEndpoint.Host("\(rawValue).local")]
    }

    /// Returns whether a host string is a bare Bonjour service name that should be qualified with `.local`.
    private nonisolated static func shouldQualifyBonjourHostWithLocalDomain(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard !value.contains("."), !value.contains(":"), !value.contains("%") else { return false }
        return value.unicodeScalars.allSatisfy { bonjourBareHostAllowedScalars.contains($0) }
    }
}
