//
//  CaptureBenchmarkReportCompatibilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import Foundation
@_spi(HostApp) @testable import MirageKitHost
import Testing
import MirageDiagnostics

#if os(macOS)
@Suite("Capture Benchmark Report Compatibility")
struct CaptureBenchmarkReportCompatibilityTests {
    @Test("Current persisted report fixture decodes")
    func currentPersistedReportFixtureDecodes() throws {
        let report = try JSONDecoder().decode(
            MirageDiagnostics.MirageHostCaptureBenchmarkReport.self,
            from: captureBenchmarkReportFixture(version: MirageDiagnostics.MirageHostCaptureBenchmarkReport.currentVersion)
        )

        #expect(report.version == MirageDiagnostics.MirageHostCaptureBenchmarkReport.currentVersion)
        #expect(report.hostName == "Bench Mac")
        #expect(report.hardwareModelIdentifier == "Mac16,7")
        #expect(report.configuration.modeSelections == [.lowPowerOff])
        #expect(report.configuration.stages.first?.id == "1080p")
        #expect(report.modeResults.first?.modeSelection == .lowPowerOff)
        #expect(report.modeResults.first?.lowPowerModeEnabled == false)
        #expect(report.modeResults.first?.stageResults.first?.status == .completed)
        #expect(report.modeResults.first?.stageResults.first?.warnings == [.displayCadenceMismatch])
        #expect(report.modeResults.first?.summary.highestValidStageID == "1080p")
        #expect(report.captureCapability?.highestValidPixelWidth == 1_920)
        #expect(
            report.isReusable(
                machineID: report.machineID,
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: report.configuration
            )
        )
    }

    @Test("Older persisted report version decodes but is not reusable")
    func olderPersistedReportVersionDecodesButIsNotReusable() throws {
        let report = try JSONDecoder().decode(
            MirageDiagnostics.MirageHostCaptureBenchmarkReport.self,
            from: captureBenchmarkReportFixture(version: MirageDiagnostics.MirageHostCaptureBenchmarkReport.currentVersion - 1)
        )

        #expect(report.version == MirageDiagnostics.MirageHostCaptureBenchmarkReport.currentVersion - 1)
        #expect(!report.didCancel)
        #expect(
            !report.isReusable(
                machineID: report.machineID,
                appVersion: "2.4",
                operatingSystemVersion: "macOS 15.4 (24E214)",
                configuration: report.configuration
            )
        )
    }
}

private func captureBenchmarkReportFixture(version: Int) -> Data {
    Data(
        """
        {
          "version": \(version),
          "machineID": "00000000-0000-0000-0000-00000000BEEF",
          "hostName": "Bench Mac",
          "hardwareModelIdentifier": "Mac16,7",
          "hardwareMachineFamily": "MacBook Pro",
          "appVersion": "2.4",
          "buildVersion": "812",
          "operatingSystemVersion": "macOS 15.4 (24E214)",
          "configuration": {
            "modeSelections": ["lowPowerOff"],
            "stages": [
              {
                "id": "1080p",
                "title": "1080p",
                "pixelWidth": 1920,
                "pixelHeight": 1080,
                "refreshRate": 120,
                "targetFrameRate": 120
              }
            ],
            "warmupDurationSeconds": 1,
            "measurementDurationSeconds": 5
          },
          "measuredAt": 770000000,
          "modeResults": [
            {
              "modeSelection": "lowPowerOff",
              "lowPowerModeEnabled": false,
              "stageResults": [
                {
                  "stage": {
                    "id": "1080p",
                    "title": "1080p",
                    "pixelWidth": 1920,
                    "pixelHeight": 1080,
                    "refreshRate": 120,
                    "targetFrameRate": 120
                  },
                  "status": "completed",
                  "reportedDisplayRefreshRate": 120,
                  "observedDisplayCadenceFPS": 118.5,
                  "sourceGenerationFPS": 120,
                  "sourcePhase": {
                    "kind": "source",
                    "rawIngressFPS": 120,
                    "validSampleFPS": 120,
                    "renderableIngressFPS": 119,
                    "cadenceAdmittedFPS": 118,
                    "deliveryFPS": 118,
                    "startupReadiness": "usableFrameSeen",
                    "averageCallbackTimeMs": 0.42,
                    "maximumCallbackTimeMs": 1.5,
                    "rawCallbackCount": 600,
                    "validSampleCount": 600,
                    "renderableSampleCount": 595,
                    "completeSampleCount": 595,
                    "idleSampleCount": 5,
                    "blankSampleCount": 0,
                    "suspendedSampleCount": 0,
                    "startedSampleCount": 1,
                    "stoppedSampleCount": 0,
                    "cadenceAdmittedCount": 590,
                    "deliveryCount": 590,
                    "cadenceDropCount": 5,
                    "admissionDropCount": 0
                  },
                  "encodeFPS": 118,
                  "sourceCapturePolicy": {
                    "effectiveCaptureRate": 120,
                    "minimumFrameIntervalRate": 120,
                    "usesNativeRefreshMinimumFrameInterval": true,
                    "sckQueueDepth": 6,
                    "usesDisplayRefreshCadence": true
                  },
                  "bottleneck": "balanced",
                  "displayCaptureCapabilityFPS": 118,
                  "validatedCapabilityFPS": 118,
                  "averageEncodeTimeMs": 2.1,
                  "warnings": ["displayCadenceMismatch"]
                }
              ],
              "summary": {
                "targetFrameRate": 120,
                "validThresholdFPS": 55,
                "sustainThresholdFPS": 108,
                "highestValidStageID": "1080p",
                "highestValidStageTitle": "1080p",
                "highestValidResolution": "1920x1080",
                "highest120FPSStageID": "1080p",
                "highest120FPSStageTitle": "1080p",
                "highest120FPSResolution": "1920x1080"
              }
            }
          ],
          "didCancel": false
        }
        """.utf8
    )
}
#endif
