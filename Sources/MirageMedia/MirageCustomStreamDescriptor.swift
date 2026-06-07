//
//  MirageCustomStreamDescriptor.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Host-published metadata for a custom stream source.
///
/// `kind` is the stable application-owned identifier used during negotiation,
/// for example `dev.example.product-display.v1`. Mirage treats it as an
/// opaque string and does not attach product-specific meaning to it.
public struct MirageCustomStreamDescriptor: Hashable, Sendable, Codable {
    /// Stable app-defined stream kind identifier.
    public let kind: String

    /// User-facing name for the custom stream source.
    public let displayName: String

    /// App-defined metadata published with the source descriptor.
    public let metadata: [String: String]

    /// Default source width in pixels.
    public let defaultWidth: Int

    /// Default source height in pixels.
    public let defaultHeight: Int

    /// Default source frame rate.
    public let defaultFrameRate: Int

    /// Whether the source accepts client input events.
    public let supportsInput: Bool

    /// Creates a descriptor for an app-defined stream source.
    public init(
        kind: String,
        displayName: String,
        metadata: [String: String] = [:],
        defaultWidth: Int,
        defaultHeight: Int,
        defaultFrameRate: Int = 60,
        supportsInput: Bool = true
    ) {
        self.kind = kind
        self.displayName = displayName
        self.metadata = metadata
        self.defaultWidth = max(1, defaultWidth)
        self.defaultHeight = max(1, defaultHeight)
        self.defaultFrameRate = max(1, min(120, defaultFrameRate))
        self.supportsInput = supportsInput
    }
}
