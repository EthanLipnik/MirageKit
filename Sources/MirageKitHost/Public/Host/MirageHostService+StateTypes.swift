//
//  MirageHostService+StateTypes.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

/// Client-side route evidence captured when a stream is accepted.
struct HostStreamMediaPathClientEvidence: Sendable, Equatable {
    let pathKind: MirageNetworkPathKind
    let mediaPathProfile: MirageMediaPathProfile
    let pathSignature: String?
    let policyPathKind: MirageNetworkPathKind
    let policyMediaPathProfile: MirageMediaPathProfile

    init(
        pathKind: MirageNetworkPathKind?,
        mediaPathProfile: MirageMediaPathProfile?,
        pathSignature: String?,
        policyPathKind: MirageNetworkPathKind? = nil,
        policyMediaPathProfile: MirageMediaPathProfile? = nil
    ) {
        self.pathKind = pathKind ?? .unknown
        self.mediaPathProfile = mediaPathProfile ?? .unknown
        self.pathSignature = pathSignature
        self.policyPathKind = policyPathKind ?? .unknown
        self.policyMediaPathProfile = policyMediaPathProfile ?? .unknown
    }

    init(policy: MirageEffectiveMediaPathPolicy) {
        self.pathKind = policy.clientPathKind
        self.mediaPathProfile = policy.clientMediaPathProfile
        self.pathSignature = policy.clientPathSignature
        self.policyPathKind = policy.clientPolicyPathKind
        self.policyMediaPathProfile = policy.clientPolicyMediaPathProfile
    }
}

@MainActor
extension MirageHostService {
    /// Advertising and startup state for the host service.
    public enum HostState: Equatable {
        /// Host is not advertising.
        case idle

        /// Host startup is in progress.
        case starting

        /// Host is advertising on the supplied control port.
        case advertising(controlPort: UInt16)

        /// Host startup or advertising failed with a user-facing message.
        case error(String)
    }

    /// Current placement and geometry metadata for a dedicated app/window virtual display.
    struct WindowVirtualDisplayState {
        let streamID: StreamID
        let displayID: CGDirectDisplayID
        let generation: UInt64
        let bounds: CGRect
        let displayVisibleBounds: CGRect
        let targetContentAspectRatio: CGFloat?
        let captureSourceRect: CGRect
        let visiblePixelResolution: CGSize
        let displayVisiblePixelResolution: CGSize
        let scaleFactor: CGFloat
        let pixelResolution: CGSize
        let clientScaleFactor: CGFloat
    }

    /// Debounced drift sample for a stream whose visible frame may need repair.
    struct WindowVisibleFrameDriftState {
        let candidateBounds: CGRect
        let candidateVisiblePixelResolution: CGSize
        let consecutiveSamples: Int
    }

    /// Client-requested desktop resize target and encoder bounds.
    struct DesktopResizeRequestState: Equatable {
        let logicalResolution: CGSize
        let transitionID: UUID?
        let requestedDisplayScaleFactor: CGFloat?
        let requestedStreamScale: CGFloat?
        let encoderMaxWidth: Int?
        let encoderMaxHeight: Int?
        let desktopGeometryContractID: UUID?
        let desktopGeometrySceneIdentity: String?
        let desktopGeometryRefreshTargetHz: Int?
    }

    /// Lifecycle state for the active desktop resize transaction.
    enum DesktopResizeTransactionState: Equatable {
        case idle
        case applying(DesktopResizeRequestState)
        case committed(DesktopResizeRequestState)
        case rolledBack(DesktopResizeRequestState)
        case failed(DesktopResizeRequestState)
    }

    /// App stream request accepted while the host is locked and waiting for the interactive session.
    struct PendingLockedAppStreamIntent {
        let request: SelectAppMessage
        let clientSessionID: UUID
        let clientID: UUID
        let createdAt: Date
        var loginStreamID: StreamID?
        var isResuming: Bool
    }

    /// Replacement window cooldown after an app window closes during streaming.
    struct PendingAppWindowReplacement {
        let streamID: StreamID
        let bundleIdentifier: String
        let clientID: UUID
        let closedWindowID: WindowID
        let slotStreamID: StreamID
        let deadline: Date
    }

    /// Host alert action exposed for a blocked app-window close request.
    struct PendingAppWindowCloseAlertAction {
        let id: String
        let title: String
        let isDestructive: Bool
        let index: Int
    }

    /// Pending close-blocked alert token awaiting a client-selected host action.
    struct PendingAppWindowCloseAlertToken {
        let clientID: UUID
        let sourceWindowID: WindowID
        let sourceApp: MirageApplication?
        let presentingStreamID: StreamID
        let actions: [PendingAppWindowCloseAlertAction]
    }

    /// Deferred app-list request resumed after interactive stream work settles.
    struct PendingAppListRequest: Equatable {
        let clientID: UUID
        var requestID: UUID
        var requestedForceRefresh: Bool
        var forceIconReset: Bool
        var priorityBundleIdentifiers: [String]
        var knownIconBundleIdentifiers: [String]
    }

    /// Deferred host hardware icon request resumed after interactive stream work settles.
    struct PendingHostHardwareIconRequest {
        let clientID: UUID
        var preferredMaxPixelSize: Int
    }

    /// Deferred host wallpaper request resumed after interactive stream work settles.
    struct PendingHostWallpaperRequest {
        let clientID: UUID
        let requestID: UUID
        var preferredMaxPixelWidth: Int
        var preferredMaxPixelHeight: Int
    }

    /// Deferred software-update status request resumed after interactive stream work settles.
    struct PendingHostSoftwareUpdateStatusRequest {
        let clientID: UUID
        var forceRefresh: Bool
    }
}
#endif
