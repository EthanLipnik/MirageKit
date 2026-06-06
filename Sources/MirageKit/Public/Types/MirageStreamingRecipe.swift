//
//  MirageStreamingRecipe.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation


/// Resolved runtime plan for launching a current Mirage stream.
public struct MirageStreamingRecipe: Sendable, Codable, Equatable {
    /// Product intent that produced this recipe.
    public let intent: MirageStreamIntent

    /// Media pipeline family to use.
    public let mediaStrategy: MirageMediaStrategy

    /// Presentation behavior for the stream.
    public let presentationPolicy: MirageMedia.MiragePresentationPolicy

    /// Optional connectivity policy for the stream.
    public let connectivityPolicy: MirageConnectivity.MirageConnectivityPolicy?

    /// Optional logical display resolution in points.
    public let displayResolution: CGSize?

    /// Optional client display scale factor.
    public let scaleFactor: CGFloat?

    /// Per-stream encoder overrides.
    public let encoderOverrides: MirageEncoderOverrides?

    /// Per-stream audio configuration.
    public let audioConfiguration: MirageMedia.MirageAudioConfiguration?

    /// Maximum visible app-window slots for app streaming.
    public let maxConcurrentVisibleWindows: Int?

    /// App-stream backing size preset.
    public let sizePreset: MirageMedia.MirageDisplaySizePreset?

    /// Whether the host should choose its current desktop resolution.
    public let useHostResolution: Bool

    /// Ordered diagnostics trace for recipe resolution.
    public let decisionTrace: MirageDiagnostics.MirageRecipeDecisionTrace

    /// Creates a streaming recipe.
    public init(
        intent: MirageStreamIntent,
        mediaStrategy: MirageMediaStrategy,
        presentationPolicy: MirageMedia.MiragePresentationPolicy,
        connectivityPolicy: MirageConnectivity.MirageConnectivityPolicy? = nil,
        displayResolution: CGSize? = nil,
        scaleFactor: CGFloat? = nil,
        encoderOverrides: MirageEncoderOverrides? = nil,
        audioConfiguration: MirageMedia.MirageAudioConfiguration? = nil,
        maxConcurrentVisibleWindows: Int? = nil,
        sizePreset: MirageMedia.MirageDisplaySizePreset? = nil,
        useHostResolution: Bool = false,
        decisionTrace: MirageDiagnostics.MirageRecipeDecisionTrace = MirageDiagnostics.MirageRecipeDecisionTrace()
    ) {
        self.intent = intent
        self.mediaStrategy = mediaStrategy
        self.presentationPolicy = presentationPolicy
        self.connectivityPolicy = connectivityPolicy
        self.displayResolution = displayResolution
        self.scaleFactor = scaleFactor
        self.encoderOverrides = encoderOverrides
        self.audioConfiguration = audioConfiguration
        self.maxConcurrentVisibleWindows = maxConcurrentVisibleWindows
        self.sizePreset = sizePreset
        self.useHostResolution = useHostResolution
        self.decisionTrace = decisionTrace
    }
}
