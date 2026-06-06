//
//  MirageEndpointClassifier.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/3/26.
//

import Foundation
import Network

/// Broad network class for a Mirage endpoint host.
public enum MirageEndpointClass: String, Sendable, Codable {
    case tailscaleIPv4
    case tailscaleIPv6
    case tailscaleMagicDNS
    case privateLAN
    case bonjour
    case publicIPv6
    case unknown
}

/// Classifies Mirage endpoint hosts for route planning and diagnostics.
public enum MirageEndpointClassifier {
    /// Classifies a Network.framework host value.
    public static func classify(_ host: NWEndpoint.Host) -> MirageEndpointClass {
        switch host {
        case let .ipv4(address):
            return classifyIPv4(address)
        case let .ipv6(address):
            return classifyIPv6(address)
        case let .name(value, _):
            return classifyHostname(value)
        default:
            return .unknown
        }
    }

    /// Classifies a hostname or IP literal entered by a user or read from discovery metadata.
    public static func classifyHostname(_ value: String) -> MirageEndpointClass {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        let unbracketed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let address = IPv4Address(unbracketed) {
            return classifyIPv4(address)
        }
        if let address = IPv6Address(unbracketed) {
            return classifyIPv6(address)
        }

        let normalized = trimmed.lowercased()
        if normalized.hasSuffix(".ts.net") || normalized.contains(".ts.") {
            return .tailscaleMagicDNS
        }
        if normalized.hasSuffix(".local") || !normalized.contains(".") {
            return .bonjour
        }
        return .unknown
    }

    private static func classifyIPv4(_ address: IPv4Address) -> MirageEndpointClass {
        let raw = address.rawValue
        guard raw.count >= 4 else { return .unknown }
        let first = raw[raw.startIndex]
        let second = raw[raw.startIndex.advanced(by: 1)]

        if first == 100 && (second & 0xC0) == 0x40 {
            return .tailscaleIPv4
        }
        if first == 10 ||
            (first == 172 && (16 ... 31).contains(second)) ||
            (first == 192 && second == 168) ||
            (first == 169 && second == 254) ||
            first == 127 {
            return .privateLAN
        }
        return .unknown
    }

    private static func classifyIPv6(_ address: IPv6Address) -> MirageEndpointClass {
        let raw = address.rawValue
        guard raw.count >= 2 else { return .unknown }
        if raw.count >= 6,
           raw[raw.startIndex] == 0xFD,
           raw[raw.startIndex.advanced(by: 1)] == 0x7A,
           raw[raw.startIndex.advanced(by: 2)] == 0x11,
           raw[raw.startIndex.advanced(by: 3)] == 0x5C,
           raw[raw.startIndex.advanced(by: 4)] == 0xA1,
           raw[raw.startIndex.advanced(by: 5)] == 0xE0 {
            return .tailscaleIPv6
        }

        let first = raw[raw.startIndex]
        let second = raw[raw.startIndex.advanced(by: 1)]
        let isLoopback = raw.dropLast().allSatisfy { $0 == 0 } && raw.last == 1
        if first == 0xFC ||
            first == 0xFD ||
            (first == 0xFE && (second & 0xC0) == 0x80) ||
            isLoopback {
            return .privateLAN
        }
        return .publicIPv6
    }
}
