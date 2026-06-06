//
//  MirageHostBufferingPolicy.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Host-side buffering policy for capture-to-encode freshness.
public enum MirageHostBufferingPolicy: String, Sendable, Codable {
    /// Preserve stability-biased buffering for difficult routes or capture paths.
    case stability
    /// Prefer the freshest captured frame and avoid Mirage-owned extra frame holds.
    case freshestFrame
}

/// Host-side buffer depth requested for custom streams.
public enum MirageHostBufferDepth: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Keep the capture inbox and encoder queue as shallow as the latency mode permits.
    case minimal
    /// Use Mirage's default buffer policy for the selected latency mode.
    case standard
    /// Add a small cushion for high-refresh streams.
    case high
    /// Add the largest bounded cushion Mirage exposes for custom streams.
    case maximum

    public static let allCases: [MirageHostBufferDepth] = [.minimal, .standard, .high, .maximum]

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimal: "Minimal Buffer"
        case .standard: "Standard Buffer"
        case .high: "High Buffer"
        case .maximum: "Maximum Buffer"
        }
    }

    public var detailDescription: String {
        switch self {
        case .minimal:
            "Lowest added buffering. Best for latency, least tolerant of ProMotion encode jitter."
        case .standard:
            "Mirage's default buffer depth for the selected latency mode."
        case .high:
            "Adds a small capture and encoder cushion for higher refresh rates."
        case .maximum:
            "Uses the largest bounded buffer cushion for custom high-refresh streams."
        }
    }

    public var captureQueueDepth: Int? {
        switch self {
        case .minimal, .standard:
            nil
        case .high:
            6
        case .maximum:
            8
        }
    }
}
