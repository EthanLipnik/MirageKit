// MirageKit - Window Streaming Framework
// https://github.com/your-repo/mirage

// MARK: - Public Types
@_exported import Foundation

// Re-export all public types
public typealias WindowID = UInt32
public typealias StreamID = UInt16
public typealias StreamSessionID = UUID

// MARK: - Version
public enum MirageKit {
    public static let version = "1.0.0"
    public static let protocolVersion: UInt8 = 1

    /// The Bonjour service type used for discovery
    public static let serviceType = "_mirage._tcp"

    /// Default ports
    public static let defaultControlPort: UInt16 = 9847
    public static let defaultDataPort: UInt16 = 9848
}
