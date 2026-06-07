//
//  MirageHostService+DesktopGeometryAnnouncements.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/2/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

#if os(macOS)

@MainActor
extension MirageHostService {
    struct DesktopGeometryAnnouncementContract {
        let contractID: UUID?
        let sceneIdentity: String?
        let presentationResolution: CGSize
        let displayPixelResolution: CGSize
        let encodedPixelResolution: CGSize
        let acceptedDisplayScaleFactor: CGFloat?
        let refreshTargetHz: Int?
    }

    func desktopPresentationResolution(
        displayPixelResolution: CGSize,
        acceptedDisplayScaleFactor: CGFloat?,
        fallbackLogicalResolution: CGSize? = nil
    ) -> CGSize {
        if let fallbackLogicalResolution,
           fallbackLogicalResolution.width > 0,
           fallbackLogicalResolution.height > 0 {
            return MirageMedia.MirageStreamGeometry.normalizedLogicalSize(fallbackLogicalResolution)
        }

        let scaleFactor = max(
            1.0,
            acceptedDisplayScaleFactor ?? desktopRequestedScaleFactor ?? sharedVirtualDisplayScaleFactor
        )
        return SharedVirtualDisplayManager.logicalResolution(
            for: displayPixelResolution,
            scaleFactor: scaleFactor
        )
    }

    func reusableCurrentDesktopGeometryContract(
        displayPixelResolution: CGSize,
        encodedPixelResolution: CGSize,
        fallbackLogicalResolution: CGSize? = nil,
        refreshTargetHz: Int? = nil
    ) -> DesktopGeometryAnnouncementContract {
        let acceptedScaleFactor = desktopCurrentGeometryDisplayScaleFactor ??
            desktopRequestedScaleFactor ??
            sharedVirtualDisplayScaleFactor
        let derivedPresentationResolution = desktopPresentationResolution(
            displayPixelResolution: displayPixelResolution,
            acceptedDisplayScaleFactor: acceptedScaleFactor,
            fallbackLogicalResolution: fallbackLogicalResolution
        )

        guard let contractID = desktopCurrentGeometryContractID,
              let storedPresentationResolution = desktopCurrentGeometryPresentationResolution,
              let storedDisplayPixelResolution = desktopCurrentGeometryDisplayPixelResolution,
              let storedEncodedPixelResolution = desktopCurrentGeometryEncodedPixelResolution,
              desktopGeometryAnnouncementContractsMatch(
                storedPresentationResolution: storedPresentationResolution,
                candidatePresentationResolution: derivedPresentationResolution,
                storedDisplayPixelResolution: storedDisplayPixelResolution,
                candidateDisplayPixelResolution: displayPixelResolution,
                storedEncodedPixelResolution: storedEncodedPixelResolution,
                candidateEncodedPixelResolution: encodedPixelResolution,
                storedAcceptedDisplayScaleFactor: desktopCurrentGeometryDisplayScaleFactor,
                candidateAcceptedDisplayScaleFactor: acceptedScaleFactor,
                storedRefreshTargetHz: desktopCurrentGeometryRefreshTargetHz,
                candidateRefreshTargetHz: refreshTargetHz
              ) else {
            return DesktopGeometryAnnouncementContract(
                contractID: nil,
                sceneIdentity: nil,
                presentationResolution: derivedPresentationResolution,
                displayPixelResolution: displayPixelResolution,
                encodedPixelResolution: encodedPixelResolution,
                acceptedDisplayScaleFactor: acceptedScaleFactor,
                refreshTargetHz: refreshTargetHz ?? desktopCurrentGeometryRefreshTargetHz
            )
        }

        return DesktopGeometryAnnouncementContract(
            contractID: contractID,
            sceneIdentity: desktopCurrentGeometrySceneIdentity,
            presentationResolution: storedPresentationResolution,
            displayPixelResolution: storedDisplayPixelResolution,
            encodedPixelResolution: storedEncodedPixelResolution,
            acceptedDisplayScaleFactor: acceptedScaleFactor,
            refreshTargetHz: desktopCurrentGeometryRefreshTargetHz
        )
    }

    func recordCurrentDesktopGeometryContract(
        contractID: UUID?,
        sceneIdentity: String?,
        presentationResolution: CGSize,
        displayPixelResolution: CGSize,
        encodedPixelResolution: CGSize,
        acceptedDisplayScaleFactor: CGFloat?,
        refreshTargetHz: Int?
    ) {
        desktopCurrentGeometryContractID = contractID
        desktopCurrentGeometrySceneIdentity = sceneIdentity
        desktopCurrentGeometryPresentationResolution = presentationResolution
        desktopCurrentGeometryDisplayPixelResolution = displayPixelResolution
        desktopCurrentGeometryEncodedPixelResolution = encodedPixelResolution
        desktopCurrentGeometryDisplayScaleFactor = acceptedDisplayScaleFactor
        desktopCurrentGeometryRefreshTargetHz = refreshTargetHz
    }

    func clearCurrentDesktopGeometryContract() {
        desktopCurrentGeometryContractID = nil
        desktopCurrentGeometrySceneIdentity = nil
        desktopCurrentGeometryPresentationResolution = nil
        desktopCurrentGeometryDisplayPixelResolution = nil
        desktopCurrentGeometryEncodedPixelResolution = nil
        desktopCurrentGeometryDisplayScaleFactor = nil
        desktopCurrentGeometryRefreshTargetHz = nil
    }

}

func desktopGeometryAnnouncementContractsMatch(
    storedPresentationResolution: CGSize,
    candidatePresentationResolution: CGSize,
    storedDisplayPixelResolution: CGSize,
    candidateDisplayPixelResolution: CGSize,
    storedEncodedPixelResolution: CGSize,
    candidateEncodedPixelResolution: CGSize,
    storedAcceptedDisplayScaleFactor: CGFloat?,
    candidateAcceptedDisplayScaleFactor: CGFloat?,
    storedRefreshTargetHz: Int?,
    candidateRefreshTargetHz: Int?
) -> Bool {
    desktopGeometryPointSizesMatch(storedPresentationResolution, candidatePresentationResolution) &&
        desktopGeometryPixelSizesMatch(storedDisplayPixelResolution, candidateDisplayPixelResolution) &&
        desktopGeometryPixelSizesMatch(storedEncodedPixelResolution, candidateEncodedPixelResolution) &&
        desktopGeometryScaleFactorsMatch(storedAcceptedDisplayScaleFactor, candidateAcceptedDisplayScaleFactor) &&
        desktopGeometryRefreshTargetsMatch(storedRefreshTargetHz, candidateRefreshTargetHz)
}

private func desktopGeometryPointSizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) <= 0.001 && abs(lhs.height - rhs.height) <= 0.001
}

private func desktopGeometryPixelSizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
}

private func desktopGeometryScaleFactorsMatch(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return abs(lhs - rhs) <= 0.001
}

private func desktopGeometryRefreshTargetsMatch(_ lhs: Int?, _ rhs: Int?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return lhs == rhs
}

#endif
