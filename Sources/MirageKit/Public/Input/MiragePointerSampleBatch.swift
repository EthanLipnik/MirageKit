//
//  MiragePointerSampleBatch.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreGraphics
import Foundation

/// Phase for a high-rate pointer sample batch.
public enum MiragePointerSampleBatchPhase: UInt8, Codable, Sendable, Hashable {
    /// Pointer is hovering without contact.
    case hover = 0

    /// Contact or button press began.
    case began = 1

    /// Pointer moved during hover or contact.
    case moved = 2

    /// Contact or button press ended normally.
    case ended = 3

    /// Contact or button press was cancelled by the input system.
    case cancelled = 4
}

/// One ordered stylus-backed pointer sample in normalized stream coordinates.
public struct MiragePointerSample: Codable, Sendable, Hashable {
    /// Location in normalized stream coordinates.
    /// Secondary desktop Lock Client Cursor input may temporarily exceed `0...1`.
    public let location: CGPoint

    /// Pressure scalar for contact samples. Hover samples use `0`.
    public let pressure: CGFloat

    /// Stylus orientation and hover metadata for this sample.
    public let stylus: MirageStylusEvent

    /// Capture timestamp for this sample.
    public let timestamp: TimeInterval

    /// Creates a stylus-backed pointer sample.
    public init(
        location: CGPoint,
        pressure: CGFloat,
        stylus: MirageStylusEvent,
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.location = location
        self.pressure = pressure
        self.stylus = stylus
        self.timestamp = timestamp
    }
}

/// Compact high-rate stylus pointer input batch.
public struct MiragePointerSampleBatch: Codable, Sendable, Hashable {
    /// Stroke or hover phase represented by the batch.
    public let phase: MiragePointerSampleBatchPhase

    /// Logical pointer button associated with the batch.
    public let button: MirageMouseButton

    /// Active keyboard modifiers captured with the batch.
    public let modifiers: MirageModifierFlags

    /// Click sequence count for boundary contact phases.
    public let clickCount: Int

    /// Whether the logical pointer button is active for the samples.
    public let isButtonPressed: Bool

    /// Ordered pointer samples. Contact batches preserve every coalesced sample.
    public let samples: [MiragePointerSample]

    /// Batch timestamp for latency measurement and queue freshness.
    public let timestamp: TimeInterval

    /// Creates a stylus pointer sample batch.
    public init(
        phase: MiragePointerSampleBatchPhase,
        button: MirageMouseButton = .left,
        modifiers: MirageModifierFlags = [],
        clickCount: Int = 1,
        isButtonPressed: Bool,
        samples: [MiragePointerSample],
        timestamp: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) {
        self.phase = phase
        self.button = button
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.isButtonPressed = isButtonPressed
        self.samples = samples
        self.timestamp = timestamp
    }

    /// Whether the batch represents Pencil hover rather than contact.
    public var isHover: Bool {
        phase == .hover
    }

    /// Last sample location, used by cursor-state tracking.
    public var lastLocation: CGPoint? {
        samples.last?.location
    }
}
