//
//  HostStreamReadyGeometryContractTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/1/26.
//

import Foundation
import CoreGraphics
@testable import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host Stream Ready Geometry Contract")
struct HostStreamReadyGeometryContractTests {
    @Test("Desktop stream ready geometry requires matching contracts")
    func desktopStreamReadyGeometryRequiresMatchingContracts() throws {
        let expected = try makeContract(width: 2752)

        #expect(
            streamReadyDesktopGeometryAcceptanceDecision(
                expected: nil,
                acknowledged: nil
            ) == .acceptNoExpectedContract
        )
        #expect(
            streamReadyDesktopGeometryAcceptanceDecision(
                expected: expected,
                acknowledged: nil
            ) == .rejectMismatchedContract
        )
        #expect(
            streamReadyDesktopGeometryAcceptanceDecision(
                expected: expected,
                acknowledged: expected
            ) == .acceptMatchedContract
        )
    }

    @Test("Desktop stream ready geometry rejects mismatched contracts")
    func desktopStreamReadyGeometryRejectsMismatchedContracts() throws {
        let expected = try makeContract(width: 2752)
        let acknowledged = try makeContract(width: 2048)

        #expect(
            streamReadyDesktopGeometryAcceptanceDecision(
                expected: expected,
                acknowledged: acknowledged
            ) == .rejectMismatchedContract
        )
    }

    @Test("AWDL desktop startup requires geometry contract before host side effects")
    func awdlDesktopStartupRequiresGeometryContractBeforeHostSideEffects() {
        #expect(
            shouldRejectAwdlDesktopStartupWithoutGeometryContract(
                usesHostResolution: false,
                transportPathKind: .awdl,
                mediaPathProfile: .awdlRadio,
                desktopGeometryContractID: nil
            )
        )
        #expect(
            !shouldRejectAwdlDesktopStartupWithoutGeometryContract(
                usesHostResolution: false,
                transportPathKind: .awdl,
                mediaPathProfile: .awdlRadio,
                desktopGeometryContractID: UUID()
            )
        )
        #expect(
            shouldRejectAwdlDesktopStartupWithoutGeometryContract(
                usesHostResolution: false,
                transportPathKind: .awdl,
                mediaPathProfile: .localWiFi,
                desktopGeometryContractID: nil
            )
        )
        #expect(
            !shouldRejectAwdlDesktopStartupWithoutGeometryContract(
                usesHostResolution: true,
                transportPathKind: .awdl,
                mediaPathProfile: .awdlRadio,
                desktopGeometryContractID: nil
            )
        )
        #expect(
            !shouldRejectAwdlDesktopStartupWithoutGeometryContract(
                usesHostResolution: false,
                transportPathKind: .wifi,
                mediaPathProfile: .localWiFi,
                desktopGeometryContractID: nil
            )
        )
    }

    @Test("Desktop geometry announcement rejects stale presentation scale encoded and refresh contracts")
    func desktopGeometryAnnouncementRejectsStaleContracts() {
        let presentation = CGSize(width: 1_376, height: 1_032)
        let display = CGSize(width: 2_752, height: 2_064)
        let encoded = CGSize(width: 2_752, height: 2_064)

        #expect(
            desktopGeometryAnnouncementContractsMatch(
                storedPresentationResolution: presentation,
                candidatePresentationResolution: presentation,
                storedDisplayPixelResolution: display,
                candidateDisplayPixelResolution: display,
                storedEncodedPixelResolution: encoded,
                candidateEncodedPixelResolution: encoded,
                storedAcceptedDisplayScaleFactor: 2.0,
                candidateAcceptedDisplayScaleFactor: 2.0,
                storedRefreshTargetHz: 60,
                candidateRefreshTargetHz: 60
            )
        )
        #expect(
            !desktopGeometryAnnouncementContractsMatch(
                storedPresentationResolution: presentation,
                candidatePresentationResolution: CGSize(width: 1_360, height: 1_032),
                storedDisplayPixelResolution: display,
                candidateDisplayPixelResolution: display,
                storedEncodedPixelResolution: encoded,
                candidateEncodedPixelResolution: encoded,
                storedAcceptedDisplayScaleFactor: 2.0,
                candidateAcceptedDisplayScaleFactor: 2.0,
                storedRefreshTargetHz: 60,
                candidateRefreshTargetHz: 60
            )
        )
        #expect(
            !desktopGeometryAnnouncementContractsMatch(
                storedPresentationResolution: presentation,
                candidatePresentationResolution: presentation,
                storedDisplayPixelResolution: display,
                candidateDisplayPixelResolution: display,
                storedEncodedPixelResolution: encoded,
                candidateEncodedPixelResolution: CGSize(width: 2_408, height: 1_806),
                storedAcceptedDisplayScaleFactor: 2.0,
                candidateAcceptedDisplayScaleFactor: 2.0,
                storedRefreshTargetHz: 60,
                candidateRefreshTargetHz: 60
            )
        )
        #expect(
            !desktopGeometryAnnouncementContractsMatch(
                storedPresentationResolution: presentation,
                candidatePresentationResolution: presentation,
                storedDisplayPixelResolution: display,
                candidateDisplayPixelResolution: display,
                storedEncodedPixelResolution: encoded,
                candidateEncodedPixelResolution: encoded,
                storedAcceptedDisplayScaleFactor: 2.0,
                candidateAcceptedDisplayScaleFactor: 1.72,
                storedRefreshTargetHz: 60,
                candidateRefreshTargetHz: 60
            )
        )
        #expect(
            !desktopGeometryAnnouncementContractsMatch(
                storedPresentationResolution: presentation,
                candidatePresentationResolution: presentation,
                storedDisplayPixelResolution: display,
                candidateDisplayPixelResolution: display,
                storedEncodedPixelResolution: encoded,
                candidateEncodedPixelResolution: encoded,
                storedAcceptedDisplayScaleFactor: 2.0,
                candidateAcceptedDisplayScaleFactor: 2.0,
                storedRefreshTargetHz: 60,
                candidateRefreshTargetHz: 45
            )
        )
    }

    @Test("Desktop virtual display startup acknowledges client contract scale")
    func desktopVirtualDisplayStartupAcknowledgesClientContractScale() {
        let scale = acceptedDesktopContractDisplayScaleFactor(
            displayPixelResolution: CGSize(width: 2_752, height: 2_064),
            presentationResolution: CGSize(width: 1_600, height: 1_200),
            fallbackScaleFactor: 2.0
        )

        #expect(abs(scale - 1.72) < 0.001)
    }

    @Test("Desktop contract scale falls back for invalid presentation geometry")
    func desktopContractScaleFallsBackForInvalidPresentationGeometry() {
        let scale = acceptedDesktopContractDisplayScaleFactor(
            displayPixelResolution: CGSize(width: 2_752, height: 2_064),
            presentationResolution: .zero,
            fallbackScaleFactor: 2.0
        )

        #expect(scale == 2.0)
    }

    @MainActor
    @Test("Shared display generation change clears reusable desktop geometry contract")
    func sharedDisplayGenerationChangeClearsReusableDesktopGeometryContract() async throws {
        let host = MirageHostService(hostName: "Geometry Contract Host")
        let contractID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF"))
        let presentation = CGSize(width: 1_376, height: 1_032)
        let display = CGSize(width: 2_752, height: 2_064)
        let encoded = CGSize(width: 2_752, height: 2_064)

        host.recordCurrentDesktopGeometryContract(
            contractID: contractID,
            sceneIdentity: "scene-main",
            presentationResolution: presentation,
            displayPixelResolution: display,
            encodedPixelResolution: encoded,
            acceptedDisplayScaleFactor: 2.0,
            refreshTargetHz: 60
        )

        let reusableBeforeGenerationChange = host.reusableCurrentDesktopGeometryContract(
            displayPixelResolution: display,
            encodedPixelResolution: encoded,
            refreshTargetHz: 60
        )
        #expect(reusableBeforeGenerationChange.contractID == contractID)

        await host.handleSharedDisplayGenerationChange(
            newContext: Self.makeDisplaySnapshot(
                displayID: 47,
                resolution: display,
                generation: 2
            ),
            previousGeneration: 1
        )

        #expect(host.desktopCurrentGeometryContractID == nil)
        let reusableAfterGenerationChange = host.reusableCurrentDesktopGeometryContract(
            displayPixelResolution: display,
            encodedPixelResolution: encoded,
            refreshTargetHz: 60
        )
        #expect(reusableAfterGenerationChange.contractID == nil)
    }

    @MainActor
    @Test("Desktop resolution change rejects missing contract when active contract exists")
    func desktopResolutionChangeRejectsMissingContractWhenActiveContractExists() throws {
        let host = MirageHostService(hostName: "Geometry Contract Host")
        let contractID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000FEED"))
        host.desktopStreamID = 9
        host.recordCurrentDesktopGeometryContract(
            contractID: contractID,
            sceneIdentity: "scene-main",
            presentationResolution: CGSize(width: 1_376, height: 1_032),
            displayPixelResolution: CGSize(width: 2_752, height: 2_064),
            encodedPixelResolution: CGSize(width: 2_752, height: 2_064),
            acceptedDisplayScaleFactor: 2.0,
            refreshTargetHz: 60
        )

        #expect(host.rejectsContractlessDesktopResolutionChange(
            streamID: 9,
            desktopGeometryContractID: nil
        ))
        #expect(!host.rejectsContractlessDesktopResolutionChange(
            streamID: 9,
            desktopGeometryContractID: contractID
        ))
        #expect(!host.rejectsContractlessDesktopResolutionChange(
            streamID: 10,
            desktopGeometryContractID: nil
        ))
    }

    private func makeContract(width: Int) throws -> StreamReadyDesktopGeometryContract {
        StreamReadyDesktopGeometryContract(
            contractID: try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000A0D1")),
            sceneIdentity: "scene-main",
            logicalWidth: 1376,
            logicalHeight: 1032,
            displayPixelWidth: width,
            displayPixelHeight: 2064,
            encodedPixelWidth: width,
            encodedPixelHeight: 2064,
            refreshTargetHz: 60
        )
    }

    private static func makeDisplaySnapshot(
        displayID: CGDirectDisplayID,
        resolution: CGSize,
        generation: UInt64
    ) -> SharedVirtualDisplayManager.DisplaySnapshot {
        SharedVirtualDisplayManager.DisplaySnapshot(
            displayID: displayID,
            spaceID: 1,
            resolution: resolution,
            scaleFactor: 2.0,
            refreshRate: 60,
            colorSpace: .sRGB,
            displayP3CoverageStatus: .unresolved,
            generation: generation,
            createdAt: Date()
        )
    }
}
