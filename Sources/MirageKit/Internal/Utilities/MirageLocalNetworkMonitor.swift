//
//  MirageLocalNetworkMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import CryptoKit
import Foundation
import Network

package struct MirageLocalNetworkSnapshot: Sendable, Equatable {
    package let currentPathKind: MirageNetworkPathKind
    package let wifiSubnetSignatures: [String]
    package let wiredSubnetSignatures: [String]

    /// Combines Wi-Fi and wired subnet fingerprints into the set used for local-network overlap checks.
    package static func subnetSignatureSet(
        wifiSubnetSignatures: [String],
        wiredSubnetSignatures: [String]
    ) -> Set<String> {
        Set(wifiSubnetSignatures).union(wiredSubnetSignatures)
    }
}

package final class MirageLocalNetworkMonitor: @unchecked Sendable {
    private let pathMonitor: NWPathMonitor
    private let pathMonitorQueue: DispatchQueue
    private let stateQueue: DispatchQueue

    private var currentPathKind: MirageNetworkPathKind = .unknown
    private var interfaceTypesByName: [String: NWInterface.InterfaceType] = [:]

    package init(label: String) {
        pathMonitor = NWPathMonitor()
        pathMonitorQueue = DispatchQueue(label: "io.miragekit.network-monitor.path.\(label)")
        stateQueue = DispatchQueue(label: "io.miragekit.network-monitor.state.\(label)")

        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.record(path)
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    /// Latest observed default-route kind and local subnet signatures.
    ///
    /// The path kind and interface map are read from the monitor queue before subnet signatures are
    /// derived from the system interface table, so callers receive a consistent point-in-time view
    /// of the last `NWPath` update.
    package var snapshot: MirageLocalNetworkSnapshot {
        let (pathKind, interfaceTypesByName) = stateQueue.sync {
            (currentPathKind, self.interfaceTypesByName)
        }
        return Self.makeSnapshot(
            currentPathKind: pathKind,
            interfaceTypesByName: interfaceTypesByName
        )
    }

    package static func makeSnapshot(
        currentPathKind: MirageNetworkPathKind,
        interfaceTypesByName: [String: NWInterface.InterfaceType]
    ) -> MirageLocalNetworkSnapshot {
        MirageLocalNetworkSnapshot(
            currentPathKind: currentPathKind,
            wifiSubnetSignatures: subnetSignatures(
                for: .wifi,
                interfaceTypesByName: interfaceTypesByName
            ),
            wiredSubnetSignatures: subnetSignatures(
                for: .wiredEthernet,
                interfaceTypesByName: interfaceTypesByName
            )
        )
    }

    package static func proximityInterfaceDiagnostics() -> String {
        struct InterfaceDiagnostic {
            var name: String
            var flags: Int32 = 0
            var addressFamilies: Set<String> = []

            var description: String {
                let families = addressFamilies.sorted().joined(separator: ",")
                let renderedFamilies = families.isEmpty ? "none" : families
                return "\(name)(" +
                    "up=\((flags & IFF_UP) != 0)," +
                    "running=\((flags & IFF_RUNNING) != 0)," +
                    "families=\(renderedFamilies)," +
                    "flags=0x\(String(flags, radix: 16))" +
                    ")"
            }
        }

        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return "unavailable"
        }
        defer {
            freeifaddrs(pointer)
        }

        var diagnosticsByName: [String: InterfaceDiagnostic] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            let name = String(cString: interface.ifa_name).lowercased()
            guard isProximityDiagnosticInterface(name) else { continue }

            var diagnostic = diagnosticsByName[name] ?? InterfaceDiagnostic(name: name)
            diagnostic.flags = Int32(interface.ifa_flags)
            if let family = interface.ifa_addr.map({ addressFamilyName(Int32($0.pointee.sa_family)) }) {
                diagnostic.addressFamilies.insert(family)
            }
            diagnosticsByName[name] = diagnostic
        }

        let diagnostics = diagnosticsByName.values.sorted { $0.name < $1.name }
        if diagnostics.isEmpty {
            return "none"
        }
        return diagnostics.map(\.description).joined(separator: ",")
    }

    private func record(_ path: NWPath) {
        let interfaceTypesByName = path.availableInterfaces.reduce(into: [String: NWInterface.InterfaceType]()) {
            partialResult,
            interface in
            partialResult[interface.name.lowercased()] = interface.type
        }
        let localDefaultRouteKind = MirageNetworkPathClassifier.classifyLocalDefaultRouteKind(
            interfaceNames: path.availableInterfaces.map(\.name),
            usesWiFi: path.usesInterfaceType(.wifi),
            usesWired: path.usesInterfaceType(.wiredEthernet),
            usesCellular: path.usesInterfaceType(.cellular),
            usesLoopback: path.usesInterfaceType(.loopback),
            usesOther: path.usesInterfaceType(.other)
        )

        stateQueue.sync {
            currentPathKind = localDefaultRouteKind
            self.interfaceTypesByName = interfaceTypesByName
        }
    }

    private static func isProximityDiagnosticInterface(_ name: String) -> Bool {
        name.hasPrefix("anpi") ||
            name.hasPrefix("apni") ||
            name.hasPrefix("awdl") ||
            name.hasPrefix("bridge") ||
            name.hasPrefix("llw")
    }

    private static func addressFamilyName(_ family: Int32) -> String {
        switch family {
        case AF_INET:
            "ipv4"
        case AF_INET6:
            "ipv6"
        case AF_LINK:
            "link"
        default:
            "af\(family)"
        }
    }

    private static func subnetSignatures(
        for interfaceType: NWInterface.InterfaceType,
        interfaceTypesByName: [String: NWInterface.InterfaceType]
    ) -> [String] {
        var signatures = Set<String>()
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer {
            freeifaddrs(pointer)
        }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next

            let name = String(cString: interface.ifa_name).lowercased()
            guard interfaceTypesByName[name] == interfaceType else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_POINTOPOINT) == 0 else {
                continue
            }

            guard let address = interface.ifa_addr,
                  let netmask = interface.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  netmask.pointee.sa_family == UInt8(AF_INET),
                  let signature = subnetSignature(address: address, netmask: netmask) else {
                continue
            }

            signatures.insert(signature)
        }

        return signatures.sorted()
    }

    private static func subnetSignature(
        address: UnsafePointer<sockaddr>,
        netmask: UnsafePointer<sockaddr>
    ) -> String? {
        let ipv4Address = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
        let ipv4Netmask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }

        let network = ipv4Address & ipv4Netmask
        let firstOctet = UInt8((network >> 24) & 0xFF)
        let secondOctet = UInt8((network >> 16) & 0xFF)
        if firstOctet == 0 || firstOctet == 127 || (firstOctet == 169 && secondOctet == 254) {
            return nil
        }

        let prefixLength = ipv4Netmask.nonzeroBitCount
        guard prefixLength > 0 else { return nil }

        var networkBytes = network.bigEndian
        let prefixByte = UInt8(clamping: prefixLength)
        var data = Data(bytes: &networkBytes, count: MemoryLayout<UInt32>.size)
        data.append(prefixByte)

        let digest = SHA256.hash(data: data)
        let truncatedHex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(prefixLength):\(truncatedHex)"
    }
}
