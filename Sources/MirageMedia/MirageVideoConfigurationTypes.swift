//
//  MirageVideoConfigurationTypes.swift
//  MirageMedia
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Stream color depth presets.
public enum MirageStreamColorDepth: String, Sendable, CaseIterable, Codable {
    /// 8-bit sRGB stream optimized for broad compatibility.
    case standard
    /// 10-bit Display P3 stream for higher color fidelity.
    case pro
    /// Highest color-depth preset for capable capture and encoder pipelines.
    case ultra

    /// Color-depth presets in fallback/restore order.
    public static let orderedCases: [MirageStreamColorDepth] = [.standard, .pro, .ultra]

    /// Localized label for settings and diagnostics UI.
    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .pro: "Pro"
        case .ultra: "Ultra"
        }
    }

    /// Next lower preset to use when reducing capture or encoder requirements.
    public var nextLowerFallback: MirageStreamColorDepth? {
        switch self {
        case .standard:
            nil
        case .pro:
            .standard
        case .ultra:
            .pro
        }
    }

    /// Next higher preset to restore after a temporary fallback.
    public var nextHigherRestore: MirageStreamColorDepth? {
        switch self {
        case .standard:
            .pro
        case .pro:
            .ultra
        case .ultra:
            nil
        }
    }

    package var colorSpace: MirageColorSpace {
        switch self {
        case .standard:
            .sRGB
        case .pro,
             .ultra:
            .displayP3
        }
    }

    package var sortRank: Int {
        switch self {
        case .standard:
            0
        case .pro:
            1
        case .ultra:
            2
        }
    }
}

/// Video codec options.
public enum MirageVideoCodec: String, Sendable, CaseIterable, Codable {
    /// HEVC video using the `hvc1` four-character code.
    case hevc = "hvc1"
    /// H.264 video using the `avc1` four-character code.
    case h264 = "avc1"
    /// ProRes 4444 video using the `ap4h` four-character code.
    case proRes4444 = "ap4h"

    /// Display label for settings and diagnostics UI.
    public var displayName: String {
        switch self {
        case .hevc: "HEVC (H.265)"
        case .h264: "H.264"
        case .proRes4444: "ProRes 4444"
        }
    }
}

/// Internal stream bit depth options.
package enum MirageVideoBitDepth: String, CaseIterable, Codable {
    case eightBit = "8bit"
    case tenBit = "10bit"

    /// Display label for diagnostics UI.
    public var displayName: String {
        switch self {
        case .eightBit: "8-bit"
        case .tenBit: "10-bit"
        }
    }
}

/// Capture and encode settings associated with one color-depth preset.
package struct MirageColorDepthDescriptor: Equatable {
    package let colorDepth: MirageStreamColorDepth
    package let bitDepth: MirageVideoBitDepth
    package let colorSpace: MirageColorSpace
    package let capturePixelFormats: [MiragePixelFormat]

    /// Creates a color-depth descriptor.
    package init(
        colorDepth: MirageStreamColorDepth,
        bitDepth: MirageVideoBitDepth,
        colorSpace: MirageColorSpace,
        capturePixelFormats: [MiragePixelFormat]
    ) {
        self.colorDepth = colorDepth
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
        self.capturePixelFormats = capturePixelFormats
    }

    /// Preferred capture pixel format for this descriptor.
    package var primaryPixelFormat: MiragePixelFormat {
        guard let primaryPixelFormat = capturePixelFormats.first else {
            preconditionFailure("Color-depth descriptors must include at least one capture pixel format.")
        }
        return primaryPixelFormat
    }
}

/// Chroma subsampling used by the video stream.
package enum MirageStreamChromaSampling: String, Codable, Equatable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"
}

/// Color space options.
package enum MirageColorSpace: String, CaseIterable, Codable {
    case sRGB
    case displayP3 = "P3"

    /// Display label for diagnostics UI.
    public var displayName: String {
        switch self {
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        }
    }
}

/// Pixel format for stream capture and encoding.
package enum MiragePixelFormat: String, CaseIterable, Codable {
    case p010
    case bgr10a2
    case bgra8
    case nv12
    case xf44
    case ayuv16

    /// Display label for diagnostics UI.
    public var displayName: String {
        switch self {
        case .p010: "10-bit (P010)"
        case .bgr10a2: "10-bit (ARGB2101010)"
        case .bgra8: "8-bit (BGRA)"
        case .nv12: "8-bit (NV12)"
        case .xf44: "10-bit (xf44)"
        case .ayuv16: "16-bit (4444 YpCbCrA)"
        }
    }
}

/// MetalFX upscaling mode.
public enum MirageUpscalingMode: String, Sendable, CaseIterable, Codable {
    /// Disable client-side upscaling.
    case off
    /// Use MetalFX spatial upscaling.
    case spatial

    /// Display label for stream settings UI.
    public var displayName: String {
        switch self {
        case .off: "Off"
        case .spatial: "Spatial"
        }
    }
}
