//
//  MirageNetworkDefaults.swift
//  MirageCore
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Stable Mirage network service and direct transport defaults.
public enum MirageNetworkDefaults {
    /// Bonjour service type used for peer discovery on the local network.
    public static let serviceType = "_mirage._tcp"

    /// TCP port used for overlay reachability probes.
    public static let overlayProbePort: UInt16 = 9852

    /// Preferred TCP listener port used for direct Mirage sessions.
    public static let directTCPPort: UInt16 = 9853

    /// Preferred UDP listener port used for direct Mirage sessions.
    public static let directUDPPort: UInt16 = 9854

    /// Preferred QUIC listener port used for direct Mirage sessions.
    public static let directQUICPort: UInt16 = 9855
}
