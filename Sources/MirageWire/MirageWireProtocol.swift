//
//  MirageWireProtocol.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Mirage-owned wire-contract versions.
public enum MirageWireProtocol {
    /// Last Mirage protocol generation before the rearchitecture wire cutover.
    public static let preRearchitectureCompatibilityVersion: UInt32 = 260604

    /// First Mirage protocol generation reserved for a breaking rearchitecture cutover.
    public static let rearchitectureCutoverVersion: UInt32 = 260605

    /// Current Mirage discovery compatibility version advertised through Loom peer metadata.
    public static let currentDiscoveryVersion: UInt32 = preRearchitectureCompatibilityVersion

    /// Current Mirage control protocol version required by both hosts and clients, encoded as YYMMDD.
    public static let currentControlVersion: UInt32 = rearchitectureCutoverVersion

    /// Current Mirage media packet version used by fixed-layout video and audio packet headers.
    public static let currentMediaPacketVersion: UInt32 = preRearchitectureCompatibilityVersion

}
