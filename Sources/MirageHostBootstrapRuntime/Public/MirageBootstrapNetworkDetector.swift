//
//  MirageBootstrapNetworkDetector.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//
//  Host bootstrap network detection for remote wake metadata.
//

import Foundation
import Loom
import SystemConfiguration

#if os(macOS)

public struct MirageBootstrapNetworkInterface: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ethernet
        case wifi
        case bridge
        case other
    }

    public var name: String
    public var displayName: String
    public var kind: Kind
    public var hardwareMACAddress: String
    public var currentMACAddress: String?
    public var ipAddresses: [String]
    public var broadcastAddresses: [String]
    public var isActive: Bool

    public init(
        name: String,
        displayName: String,
        kind: Kind,
        hardwareMACAddress: String,
        currentMACAddress: String? = nil,
        ipAddresses: [String] = [],
        broadcastAddresses: [String] = [],
        isActive: Bool = false
    ) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
        self.hardwareMACAddress = hardwareMACAddress
        self.currentMACAddress = currentMACAddress
        self.ipAddresses = ipAddresses
        self.broadcastAddresses = broadcastAddresses
        self.isActive = isActive
    }
}

public struct MirageBootstrapNetworkSnapshot: Equatable, Sendable {
    public var endpoints: [LoomBootstrapEndpoint]
    public var wakeOnLANMACAddress: String
    public var wakeOnLANBroadcasts: [String]
    public var wakeInterfaceName: String?
    public var wakeInterfaceDisplayName: String?
    public var isWakeInterfaceWiFi: Bool
    public var hasWiFiPrivateAddressWarning: Bool

    public init(
        endpoints: [LoomBootstrapEndpoint],
        wakeOnLANMACAddress: String,
        wakeOnLANBroadcasts: [String],
        wakeInterfaceName: String?,
        wakeInterfaceDisplayName: String?,
        isWakeInterfaceWiFi: Bool,
        hasWiFiPrivateAddressWarning: Bool
    ) {
        self.endpoints = endpoints
        self.wakeOnLANMACAddress = wakeOnLANMACAddress
        self.wakeOnLANBroadcasts = wakeOnLANBroadcasts
        self.wakeInterfaceName = wakeInterfaceName
        self.wakeInterfaceDisplayName = wakeInterfaceDisplayName
        self.isWakeInterfaceWiFi = isWakeInterfaceWiFi
        self.hasWiFiPrivateAddressWarning = hasWiFiPrivateAddressWarning
    }
}

public enum MirageBootstrapNetworkDetector {
    public static func detect(defaultPort: UInt16) -> MirageBootstrapNetworkSnapshot {
        let ifconfigText = runCommand(executablePath: "/sbin/ifconfig", arguments: [])
        return snapshot(
            hardwareInterfaces: hardwareInterfaces(),
            ifconfigText: ifconfigText,
            defaultPort: defaultPort
        )
    }

    public static func snapshot(
        hardwareInterfaces: [MirageBootstrapNetworkInterface],
        ifconfigText: String,
        defaultPort: UInt16
    ) -> MirageBootstrapNetworkSnapshot {
        let liveInterfaces = parseIfconfig(ifconfigText)
        let mergedInterfaces = hardwareInterfaces.map { hardwareInterface in
            var merged = hardwareInterface
            if let liveInterface = liveInterfaces[hardwareInterface.name] {
                merged.currentMACAddress = liveInterface.currentMACAddress
                merged.ipAddresses = liveInterface.ipAddresses
                merged.broadcastAddresses = liveInterface.broadcastAddresses
                merged.isActive = liveInterface.isActive
            }
            return merged
        }

        let endpoints = dedupe(
            mergedInterfaces.flatMap { interface in
                interface.ipAddresses.map { ip in
                    LoomBootstrapEndpoint(host: ip, port: defaultPort, source: .auto)
                }
            },
            by: { "\($0.host.lowercased()):\($0.port)" }
        )

        guard let wakeInterface = wakeInterface(from: mergedInterfaces) else {
            return MirageBootstrapNetworkSnapshot(
                endpoints: endpoints,
                wakeOnLANMACAddress: "",
                wakeOnLANBroadcasts: [],
                wakeInterfaceName: nil,
                wakeInterfaceDisplayName: nil,
                isWakeInterfaceWiFi: false,
                hasWiFiPrivateAddressWarning: false
            )
        }

        let currentMAC = wakeInterface.currentMACAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hardwareMAC = wakeInterface.hardwareMACAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let wakeMAC = currentMAC?.isEmpty == false ? currentMAC! : hardwareMAC
        let broadcasts = dedupe(
            wakeInterface.broadcastAddresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            by: { $0 }
        )
        let isWiFi = wakeInterface.kind == .wifi
        let hasPrivateAddressWarning = isWiFi &&
            currentMAC?.isEmpty == false &&
            !macAddressesEqual(currentMAC!, hardwareMAC)

        return MirageBootstrapNetworkSnapshot(
            endpoints: endpoints,
            wakeOnLANMACAddress: wakeMAC,
            wakeOnLANBroadcasts: broadcasts,
            wakeInterfaceName: wakeInterface.name,
            wakeInterfaceDisplayName: wakeInterface.displayName,
            isWakeInterfaceWiFi: isWiFi,
            hasWiFiPrivateAddressWarning: hasPrivateAddressWarning
        )
    }

    public static func isValidWakeMACAddress(_ macAddress: String) -> Bool {
        normalizedMACAddress(macAddress).count == 12
    }

    private static func wakeInterface(
        from interfaces: [MirageBootstrapNetworkInterface]
    ) -> MirageBootstrapNetworkInterface? {
        interfaces
            .filter { interface in
                interface.isActive &&
                    !interface.broadcastAddresses.isEmpty &&
                    isWakeCandidate(interface)
            }
            .sorted { lhs, rhs in
                let leftRank = wakeRank(lhs)
                let rightRank = wakeRank(rhs)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    private static func isWakeCandidate(_ interface: MirageBootstrapNetworkInterface) -> Bool {
        guard interface.kind == .ethernet || interface.kind == .wifi else { return false }
        let mac = interface.currentMACAddress?.isEmpty == false ?
            interface.currentMACAddress! :
            interface.hardwareMACAddress
        guard isValidWakeMACAddress(mac) else { return false }
        return !hasVirtualOUI(mac)
    }

    private static func wakeRank(_ interface: MirageBootstrapNetworkInterface) -> Int {
        switch interface.kind {
        case .ethernet:
            return 0
        case .wifi:
            return 1
        case .bridge, .other:
            return 2
        }
    }

    private static func hasVirtualOUI(_ macAddress: String) -> Bool {
        let normalized = normalizedMACAddress(macAddress)
        return normalized.hasPrefix("de6e68") ||
            normalized.hasPrefix("005056") ||
            normalized.hasPrefix("080027")
    }

    private static func macAddressesEqual(_ lhs: String, _ rhs: String) -> Bool {
        normalizedMACAddress(lhs) == normalizedMACAddress(rhs)
    }

    private static func normalizedMACAddress(_ macAddress: String) -> String {
        macAddress
            .lowercased()
            .filter { $0.isHexDigit }
    }

    private static func hardwareInterfaces() -> [MirageBootstrapNetworkInterface] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return []
        }

        return interfaces.compactMap { interface in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let macAddress = SCNetworkInterfaceGetHardwareAddressString(interface) as String? else {
                return nil
            }
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            return MirageBootstrapNetworkInterface(
                name: name,
                displayName: displayName,
                kind: kind(for: type),
                hardwareMACAddress: macAddress
            )
        }
    }

    private static func kind(for interfaceType: String?) -> MirageBootstrapNetworkInterface.Kind {
        if interfaceType == kSCNetworkInterfaceTypeEthernet as String {
            return .ethernet
        }
        if interfaceType == kSCNetworkInterfaceTypeIEEE80211 as String {
            return .wifi
        }
        if interfaceType == "Bridge" {
            return .bridge
        }
        return .other
    }

    private struct LiveInterface {
        var currentMACAddress: String?
        var ipAddresses: [String] = []
        var broadcastAddresses: [String] = []
        var isActive = false
    }

    private static func parseIfconfig(_ text: String) -> [String: LiveInterface] {
        var activeInterface: String?
        var interfaces: [String: LiveInterface] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                guard let colon = line.firstIndex(of: ":") else {
                    activeInterface = nil
                    continue
                }
                let name = String(line[..<colon])
                activeInterface = name
                var entry = interfaces[name] ?? LiveInterface()
                entry.isActive = line.contains("<") &&
                    line.contains("UP") &&
                    line.contains("RUNNING")
                interfaces[name] = entry
                continue
            }

            guard let interface = activeInterface else { continue }
            var entry = interfaces[interface] ?? LiveInterface()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("ether ") {
                entry.currentMACAddress = trimmed
                    .replacingOccurrences(of: "ether ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("inet ") {
                let components = trimmed.split(separator: " ")
                if components.count >= 2 {
                    let ip = String(components[1])
                    if ip != "127.0.0.1" {
                        entry.ipAddresses.append(ip)
                    }
                }
                if let broadcastIndex = components.firstIndex(of: "broadcast"),
                   components.indices.contains(broadcastIndex + 1) {
                    entry.broadcastAddresses.append(String(components[broadcastIndex + 1]))
                }
            } else if trimmed.hasPrefix("status: ") {
                entry.isActive = entry.isActive &&
                    trimmed.localizedCaseInsensitiveContains("active") &&
                    !trimmed.localizedCaseInsensitiveContains("inactive")
            }

            interfaces[interface] = entry
        }

        return interfaces
    }

    private static func dedupe<T, Key: Hashable>(
        _ values: [T],
        by key: (T) -> Key
    ) -> [T] {
        var seen = Set<Key>()
        return values.filter { value in
            let key = key(value)
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func runCommand(executablePath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData + errorData, encoding: .utf8) ?? ""
    }
}

#endif
