//
//  MirageLocalNetworkEndpointHint.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/6/26.
//

import Foundation

/// Privacy-safe local-network fingerprint used to match CloudKit endpoint hints.
public struct MirageLocalNetworkSignatureContext: Codable, Hashable, Sendable {
    /// Hashed IPv4 subnet signatures observed on Wi-Fi interfaces.
    public let wifiSubnetSignatures: [String]
    /// Hashed IPv4 subnet signatures observed on wired Ethernet interfaces.
    public let wiredSubnetSignatures: [String]

    /// Creates a local-network signature context from already-hashed subnet signatures.
    public init(
        wifiSubnetSignatures: [String],
        wiredSubnetSignatures: [String]
    ) {
        self.wifiSubnetSignatures = Self.normalizedSignatures(wifiSubnetSignatures)
        self.wiredSubnetSignatures = Self.normalizedSignatures(wiredSubnetSignatures)
    }

    /// All subnet signatures in this context.
    public var allSubnetSignatures: Set<String> {
        Set(wifiSubnetSignatures).union(wiredSubnetSignatures)
    }

    /// Whether the context contains at least one subnet signature.
    public var isEmpty: Bool {
        allSubnetSignatures.isEmpty
    }

    /// Returns whether two contexts describe overlapping local-network evidence.
    public func intersects(_ other: MirageLocalNetworkSignatureContext) -> Bool {
        !allSubnetSignatures.isDisjoint(with: other.allSubnetSignatures)
    }

    private static func normalizedSignatures(_ signatures: [String]) -> [String] {
        Array(
            Set(
                signatures
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }
}

/// Last known direct endpoint addresses for a specific local network.
public struct MirageLocalNetworkEndpointHint: Codable, Hashable, Sendable {
    /// Network fingerprint that must match before the hosts are used.
    public let network: MirageLocalNetworkSignatureContext
    /// Direct host addresses observed for the host on that network.
    public let hosts: [String]
    /// Time the addresses were observed.
    public let observedAt: Date

    /// Creates a bounded local-network endpoint hint.
    public init(
        network: MirageLocalNetworkSignatureContext,
        hosts: [String],
        observedAt: Date
    ) {
        self.network = network
        self.hosts = Self.normalizedHosts(hosts)
        self.observedAt = observedAt
    }

    /// Returns whether this hint applies to the supplied current network context.
    public func matches(_ currentNetwork: MirageLocalNetworkSignatureContext) -> Bool {
        !network.isEmpty && network.intersects(currentNetwork)
    }

    private static func normalizedHosts(_ hosts: [String]) -> [String] {
        var seenHosts = Set<String>()
        var normalizedHosts: [String] = []
        for host in hosts {
            let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedHost.isEmpty,
                  seenHosts.insert(normalizedHost).inserted else {
                continue
            }
            normalizedHosts.append(normalizedHost)
        }
        return normalizedHosts
    }
}
