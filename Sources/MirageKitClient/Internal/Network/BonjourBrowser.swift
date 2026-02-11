//
//  BonjourBrowser.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation
import Network
import Observation
import MirageKit
import CryptoKit

/// Discovers Mirage hosts on the local network via Bonjour
@Observable
@MainActor
public final class MirageDiscovery {
    /// Discovered hosts on the network
    public private(set) var discoveredHosts: [MirageHost] = []

    /// Whether discovery is currently active
    public private(set) var isSearching: Bool = false

    /// Whether peer-to-peer WiFi discovery is enabled
    public var enablePeerToPeer: Bool = true

    private var browser: NWBrowser?
    private let serviceType: String
    private var hostsByEndpoint: [NWEndpoint: MirageHost] = [:]

    public init(serviceType: String = MirageKit.serviceType, enablePeerToPeer: Bool = true) {
        self.serviceType = serviceType
        self.enablePeerToPeer = enablePeerToPeer
    }

    /// Start discovering hosts on the network
    public func startDiscovery() {
        guard !isSearching else {
            MirageLogger.discovery("Already searching")
            return
        }

        MirageLogger.discovery("Starting discovery for \(serviceType)")

        let parameters = NWParameters()
        parameters.includePeerToPeer = enablePeerToPeer

        browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: parameters
        )

        browser?.stateUpdateHandler = { [weak self] state in
            MirageLogger.discovery("Browser state: \(state)")
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            MirageLogger.discovery("Results changed: \(results.count) hosts, \(changes.count) changes")
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results, changes: changes)
            }
        }

        browser?.start(queue: .main)
        isSearching = true
    }

    /// Stop discovering hosts
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isSearching = true
        case .cancelled,
             .failed:
            isSearching = false
        default:
            break
        }
    }

    private func handleBrowseResults(_: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case let .added(result):
                addHost(from: result)
            case let .removed(result):
                removeHost(for: result.endpoint)
            case let .changed(old, new, _):
                removeHost(for: old.endpoint)
                addHost(from: new)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func addHost(from result: NWBrowser.Result) {
        // Extract host info from result
        var hostName = "Unknown Host"
        var capabilities = MirageHostCapabilities()
        var txtDict: [String: String] = [:]

        // Get service name and TXT record
        if case let .service(name, _, _, _) = result.endpoint { hostName = name }

        // Parse TXT record for capabilities
        let metadata = result.metadata
        if case let .bonjour(txtRecord) = metadata {
            for key in txtRecord.dictionary.keys {
                if let value = txtRecord.dictionary[key] { txtDict[key] = value }
            }
            capabilities = MirageHostCapabilities.from(txtRecord: txtDict)
            MirageLogger.discovery(
                "Host metadata \(hostName): did=\(capabilities.deviceID?.uuidString ?? "nil") hwm=\(capabilities.hardwareModelIdentifier ?? "nil") hwi=\(capabilities.hardwareIconName ?? "nil") hwf=\(capabilities.hardwareMachineFamily ?? "nil") keys=\(txtDict.keys.sorted())"
            )
        }

        // Use TXT device ID when available; otherwise derive a stable fallback from endpoint identity.
        let hostID = capabilities.deviceID ?? fallbackHostID(endpoint: result.endpoint, hostName: hostName)

        let host = MirageHost(
            id: hostID,
            name: hostName,
            deviceType: .mac, // Hosts are always Macs
            endpoint: result.endpoint,
            capabilities: capabilities
        )

        hostsByEndpoint[result.endpoint] = host
        updateHostsList()
    }

    private func fallbackHostID(endpoint: NWEndpoint, hostName: String) -> UUID {
        let source = "\(hostName)|\(endpoint.debugDescription)"
        let digest = SHA256.hash(data: Data(source.utf8))
        let bytes = Array(digest)
        var uuidBytes = Array(bytes.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80

        let uuid = uuid_t(
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )
        return UUID(uuid: uuid)
    }

    private func removeHost(for endpoint: NWEndpoint) {
        hostsByEndpoint.removeValue(forKey: endpoint)
        updateHostsList()
    }

    private func updateHostsList() {
        discoveredHosts = Array(hostsByEndpoint.values).sorted { $0.name < $1.name }
    }

    /// Force refresh the hosts list
    public func refresh() {
        stopDiscovery()
        hostsByEndpoint.removeAll()
        discoveredHosts.removeAll()
        startDiscovery()
    }
}
