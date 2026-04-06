//
//  MessageTypes+HostMetadata.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/29/26.
//
//  Host metadata request/response message definitions.
//

import Foundation

package struct HostHardwareIconRequestMessage: Codable, Sendable {
    package let preferredMaxPixelSize: Int

    package init(preferredMaxPixelSize: Int) {
        self.preferredMaxPixelSize = preferredMaxPixelSize
    }
}

package struct HostHardwareIconMessage: Codable, Sendable {
    package let pngData: Data
    package let iconName: String?
    package let hardwareModelIdentifier: String?
    package let hardwareMachineFamily: String?

    package init(
        pngData: Data,
        iconName: String?,
        hardwareModelIdentifier: String?,
        hardwareMachineFamily: String?
    ) {
        self.pngData = pngData
        self.iconName = iconName
        self.hardwareModelIdentifier = hardwareModelIdentifier
        self.hardwareMachineFamily = hardwareMachineFamily
    }
}

package struct HostWallpaperRequestMessage: Codable, Sendable {
    package let requestID: UUID
    package let preferredMaxPixelWidth: Int
    package let preferredMaxPixelHeight: Int

    package init(
        requestID: UUID,
        preferredMaxPixelWidth: Int,
        preferredMaxPixelHeight: Int
    ) {
        self.requestID = requestID
        self.preferredMaxPixelWidth = preferredMaxPixelWidth
        self.preferredMaxPixelHeight = preferredMaxPixelHeight
    }
}

package struct HostWallpaperMessage: Codable, Sendable {
    package let requestID: UUID?
    package let imageData: Data?
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let bytesPerPixelEstimate: Int
    package let errorMessage: String?

    package init(
        requestID: UUID? = nil,
        imageData: Data? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        bytesPerPixelEstimate: Int,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.imageData = imageData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bytesPerPixelEstimate = bytesPerPixelEstimate
        self.errorMessage = errorMessage
    }
}
